dofile "$CONTENT_DATA/Scripts/game/survival_constants.lua"
dofile "$CONTENT_DATA/Scripts/game/survival_units.lua"
dofile "$CONTENT_DATA/Scripts/game/util/Timer.lua"
dofile "$CHALLENGE_DATA/Scripts/challenge/world_util.lua"
dofile "$CONTENT_DATA/Scripts/game/managers/HudManager.lua"
dofile "$CONTENT_DATA/Scripts/game/survival_raids.lua"
dofile "$CONTENT_DATA/Scripts/game/raid_util.lua"
dofile "$CONTENT_DATA/Scripts/game/managers/DialogManager.lua"
dofile "$CONTENT_DATA/Scripts/game/managers/QuestManager.lua"

-- Server side
RaidManager = class( nil )

-- Gui
local RaidPanelGui = {}
RaidPanelGui.root = dofile( "$SURVIVAL_DATA/Gui/JsonGuis/RaidPanel.gui" )
RaidPanelGui.index = IndexWidgets( RaidPanelGui.root )
RaidPanelGui.index.RaidPanel.Alpha = 0
RaidPanelGui.raidBars = {
	RaidPanelGui.index.RaidBarStep1,
	RaidPanelGui.index.RaidBarStep2,
	RaidPanelGui.index.RaidBarStep3
}
RaidPanelGui.milestones = {
	RaidPanelGui.index.MilestoneStep1,
	RaidPanelGui.index.MilestoneStep2
}

local MilestoneEffectBoxNames = {}
for i = 1, #RaidPanelGui.milestones do
	MilestoneEffectBoxNames[i] = RaidPanelGui.milestones[i].Childs[1].Name
end

local BarSectionWidth = 100
local SuperBarWidth = 300

local SuperBarAlphaSwapTime = 0.35


RaidPanelGui.index.RaidBarStep1.width = BarSectionWidth
RaidPanelGui.index.RaidBarStep2.width = BarSectionWidth
RaidPanelGui.index.RaidBarStep3.width = BarSectionWidth
RaidPanelGui.index.RaidBarFillSuper.width = SuperBarWidth

local PreviewBarColor1 = sm.color.new( 1.0, 1.0, 1.0 )
local PreviewBarColor2 = sm.color.new(  0.7, 0.7, 0.7 )
local OscillationFrequency = 0.55

-- Constants
-- 1: master. 2: the attack timeline is attackStartTick instead of tickCounter, fleeingRaids were added, plantingLocations dropped and raids that have started their attack carry cropArea.
local VERSION = 2

local MultiDropRandomOffset = 2.0

local RaidIncomingTickTime = 40 * 60.0 -- The countdown time it takes for a triggered raid to start spawning waves
local RaidResetOnPlantTickTime = 40 * 10.0
local RaidTimeoutTickTime = RAIDER_TICK_LIFETIME -- How long the attack lasts after its last group has spawned

local InEffectDelayTicks = 40 * 12.0
local DelayBeforeBarMovement = 0.2
local BarMoveDuration = 0.4

local DropEffectTravelDistance = 500
local DropEffectRadius = 512 -- Clients farther than this from the raid don't play its drop effects
local DropEffectDuration = 5.2
local MarkerTickLifetime = 40 * 12.0
local RaidMarkerOffset = sm.vec3.new( 0, 0, 0.9 )
local RaidCountdownEffectValues = {
	[30] = true,
	[20] = true,
	[10] = true,
	[5] = true,
	[4] = true,
	[3] = true,
	[2] = true,
	[1] = true
}

local RaiderMissingRespawnTicks = 40 * 10 -- how long a missing raider will wait before respawning
local RaidCropAreaMargin = 5.0 -- added to the radius around the raid's crops so crops next to them count as part of the area

local DoorDissolveDuration = 0.5
local DoorDissolveDelay = 16.0

local GuiFadeInDuration = 0.075
local GuiFadeOutDuration = 0.1

local function GetRaidGuiMilestone( value )
	local level = GetRaidLevel( value )
	return clamp( math.floor( ( level - 1 ) / 2 ), 0, 2 )
end

local function GetRaidGuiFraction( value )
	local level = GetRaidLevel( value )
	if level > 6 then
		return 1.0
	end
	local fraction = GetRaidLevelFraction( value )
	return ( ( level - 1 ) % 2 + fraction ) / 2
end

local function GetRaidIsSuper( value )
	return GetRaidLevel( value ) > 6
end

local function GetRaidSuperFraction( value )
	if not GetRaidIsSuper( value ) then
		return 0
	end
	local fraction = GetRaidLevelFraction( value )
	return math.log( fraction + 1, 2 )
end

local function GetRaidEnemies( raid )
	if raid.attackData.groupSpawns == nil then
		raid.attackData.groupSpawns = {}
	end
	local spawnTickDelay = InEffectDelayTicks
	local spawnPointIndex = 1

	local initialGroup = GetInitialRaidGroup( raid.value )
	if initialGroup then
		raid.attackData.groupSpawns[#raid.attackData.groupSpawns+1] = { enemyList = initialGroup.enemyList, tickDelay = spawnTickDelay, spawnIndex = spawnPointIndex }
		spawnTickDelay = spawnTickDelay + initialGroup.nextDelay
		spawnPointIndex = spawnPointIndex + 1
	end

	local groups = GetRaidGroups( raid.value )
	for _,groupData in ipairs( groups ) do
		raid.attackData.groupSpawns[#raid.attackData.groupSpawns+1] = { enemyList = groupData.enemyList, tickDelay = spawnTickDelay, spawnIndex = spawnPointIndex }
		spawnTickDelay = spawnTickDelay + groupData.nextDelay
		spawnPointIndex = spawnPointIndex + 1
	end

	raid.totalEnemyCount = 0
	raid.lastSpawnTick = 0
	for _,spawn in ipairs( raid.attackData.groupSpawns ) do
		for _,enemyData in ipairs( spawn.enemyList ) do
			raid.totalEnemyCount = raid.totalEnemyCount + enemyData.quantity
		end
		raid.lastSpawnTick = math.max( raid.lastSpawnTick, spawn.tickDelay )
	end
	raid.timeoutTick = raid.lastSpawnTick + RaidTimeoutTickTime
end

local RaidRadiusMargin = 1.0 -- Entering needs this much inside the radius and leaving this much outside, so the border doesn't flicker

function RaidManager.IsWithinRaidRadius( distance2, wasInside )
	local radius = wasInside and ( RAID_RADIUS + RaidRadiusMargin ) or ( RAID_RADIUS - RaidRadiusMargin )
	return distance2 <= radius * radius
end

local function IsPositionCellLoaded( world, position )
	return world:isCellLoadedServer( math.floor( position.x / 64 ), math.floor( position.y / 64 ) )
end

local function HasNearbyPlayer( raidCenter, wasNearby )
	local players = sm.player.getAllPlayers()
	for _, player in ipairs( players ) do
		if sm.exists( player.character ) then
			local distance2 = ( raidCenter - player.character.worldPosition ):length2()
			if RaidManager.IsWithinRaidRadius( distance2, wasNearby ) then
				return true
			end
		end
	end
	return false
end
















































































-- The horizontal circle around the raid's crops, fixed when the attack starts. Crops of any kind inside it count as part of the raid area.
local function ComputeCropArea( raid )
	local center, radius = sm.util.boundingCircle( raid.cropPositions )



	return { center = center, radius = radius + RaidCropAreaMargin }
end

local function MigrateSavedRaids( saved )
	local currentTick = sm.game.getCurrentTick()
	for _, raids in pairs( saved.worldRaids ) do
		for _, raid in pairs( raids ) do
			-- A raid before its attack has a tickCounter of 0 and no groupSpawns; its attackStartTick is set when the attack starts
			if raid.tickCounter and raid.attackData.groupSpawns then
				raid.attackStartTick = currentTick - raid.tickCounter
				raid.timeoutProgress = math.max( raid.tickCounter - raid.lastSpawnTick, 0 )
			end
			raid.tickCounter = nil
			raid.plantingLocations = nil
			-- The crops it started with are gone, so the area is built from the ones that remain
			if raid.timeoutTick and raid.cropArea == nil then
				raid.cropArea = ComputeCropArea( raid )
			end
		end
	end
	saved.fleeingRaids = saved.fleeingRaids or {}
	saved.version = VERSION
end

--[[ Server ]]
function RaidManager.server_onCreate( self )
	g_raidManager = self
	self.sv = {}
	self.sv.navmeshHandles = {}
	self.sv.spawnPointCellHandles = {}
	self.sv.finishedNavMeshLoads = {}
	self.sv.activeRaidLoadHandles = {}
	self.sv.raidPaths = {}
	self.sv.raidsPathGenerationData = {}
	self.sv.raiderMissingTicks = {}
	self.sv.saved = sm.storage.load( STORAGE_CHANNEL_RAIDMANAGER )
	if self.sv.saved == nil then
		self.sv.saved = {}
		self.sv.saved.worldRaids = {}
		self.sv.saved.fleeingRaids = {}
		self.sv.saved.version = VERSION
		sm.storage.save( STORAGE_CHANNEL_RAIDMANAGER, self.sv.saved )
	elseif ( self.sv.saved.version or 1 ) < VERSION then
		MigrateSavedRaids( self.sv.saved )
		sm.storage.save( STORAGE_CHANNEL_RAIDMANAGER, self.sv.saved )
	end
	self.sv.isDirty = false
	self:sv_syncClientData()
	self.sv.synchToClients = false
end

function RaidManager.server_onFixedUpdate( self, dt )
	-- Synch client data
	if self.sv.synchToClients then
		self:sv_syncClientData()
		self.sv.synchToClients = false
	end
	if self.sv.isDirty then
		sm.storage.save( STORAGE_CHANNEL_RAIDMANAGER, self.sv.saved )
		self.sv.isDirty = false
	end
end

function RaidManager.server_onUnload( self )
	sm.storage.save( STORAGE_CHANNEL_RAIDMANAGER, self.sv.saved )
end

function RaidManager.sv_syncClientData( self )
	local worldRaidSync = {}
	for worldId,raids in pairs( self.sv.saved.worldRaids ) do
		worldRaidSync[worldId] = {}
		for raidKey,raid in pairs( raids ) do
			local groupSpawns = {}
			if raid.attackData.groupSpawns then
				for _,groupSpawn in ipairs( raid.attackData.groupSpawns ) do
					groupSpawns[#groupSpawns+1] = {
						tickDelay = groupSpawn.tickDelay,
						spawnIndex = groupSpawn.spawnIndex,
						dropStartTick = raid.attackStartTick + groupSpawn.tickDelay - InEffectDelayTicks
					}
				end
			end
			local attackData = {
				attackPosition = raid.attackData.attackPosition,
				attackTick = raid.attackData.attackTick,
				spawnPositions = raid.attackData.spawnPositions,
				groupSpawns = groupSpawns
			}
			worldRaidSync[worldId][raidKey] = {
				key = raidKey,
				level = raid.level,
				value = raid.value,
				center = raid.center,
				attackData = attackData,
				timeoutTick = raid.timeoutTick,
			}
		end
	end
	self.network:setClientData( worldRaidSync )
end

function RaidManager.sv_getRaidKey( self, worldId, worldPosition )
	local overlappingRaids = {}
	local raids = self.sv.saved.worldRaids[worldId] or {}
	for raidKey, raid in pairs( raids ) do
		local distance2 = ( raid.center - worldPosition ):length2()
		if distance2 <= RAID_RADIUS * RAID_RADIUS then
			overlappingRaids[#overlappingRaids+1] = { raidKey = raidKey, distance2 = distance2 }
		end
	end
	table.sort( overlappingRaids, function( a, b ) return a.distance2 < b.distance2 end ) -- Shortest distance first
	if #overlappingRaids > 0 then
		-- Return first raid
		return overlappingRaids[1].raidKey
	end
	return nil
end

function RaidManager.sv_getRaidAtPosition( self, worldId, worldPosition )
	local raids = self.sv.saved.worldRaids[worldId] or {}
	local raidKey = self:sv_getRaidKey( worldId, worldPosition )
	if raidKey then
		-- Return first raid
		return raids[raidKey]
	end
	return nil
end

function RaidManager.Sv_AreaHasActiveRaid( position, worldId )
	if g_raidManager then
		return g_raidManager:sv_areaHasActiveRaid( position, worldId )
	end
	return false
end

function RaidManager.sv_areaHasActiveRaid( self, position, worldId )
	local raid = self:sv_getRaidAtPosition( worldId, position )
	return raid ~= nil and raid.timeoutTick ~= nil
end

-- Callers must have passed Sv_AreaHasActiveRaid: a raid whose attack has started takes no new crops.
-- Returns the key of the raid that adopted the crop, or nil when none did.
function RaidManager.Sv_DetectCrop( cropHarvestable )
	if g_raidManager then
		return g_raidManager:sv_detectCrop( cropHarvestable )
	end
	return nil
end

function RaidManager.sv_detectCrop( self, cropHarvestable )
	if g_disableRaids or GetPlantValue( tostring( cropHarvestable.uuid ) ) == 0 then return nil end
	local worldId = cropHarvestable:getWorld().id
	local raid = self:sv_getRaidAtPosition( worldId, cropHarvestable.worldPosition )
	local currentTick = sm.game.getCurrentTick()

	if raid == nil then
		-- Create a new raid
		raid = {}
		raid.center = cropHarvestable.worldPosition
		-- The tick keeps keys unique, so raiders of an earlier raid at this spot never mistake this raid for theirs
		raid.key = worldId.."|"..math.floor( raid.center.x ).."|"..math.floor( raid.center.y ).."|"..math.floor( raid.center.z ).."|"..currentTick
		raid.cropPositions = {}
		raid.existingCrops = {}
		raid.value = 0
		raid.maxValue = 0
		raid.level = 0
		raid.plantingOrder = {}
		self.sv.saved.worldRaids[worldId] = self.sv.saved.worldRaids[worldId] or {}
		self.sv.saved.worldRaids[worldId][raid.key] = raid
	end
	-- Add crop
	raid.value = raid.value + GetPlantValue( tostring( cropHarvestable.uuid ) )
	raid.maxValue = raid.value
	raid.cropPositions[#raid.cropPositions+1] = cropHarvestable.worldPosition
	raid.existingCrops[cropHarvestable.id] = cropHarvestable
	raid.center = sm.util.geometricMedian( raid.cropPositions, nil, 12 )
	raid.plantingOrder[#raid.plantingOrder+1] = { uid = cropHarvestable.uuid, position = cropHarvestable.worldPosition }

	if raid.attackData and raid.attackData.attackTick and currentTick <= raid.attackData.attackTick - RaidIncomingTickTime + RaidResetOnPlantTickTime then
		raid.attackData.attackTick = currentTick + RaidIncomingTickTime





	end

	raid.level = GetRaidLevel( raid.value ) -- Update raid level





	if raid.attackData == nil then
		raid.attackData = { attackPosition = raid.center, attackTick = currentTick + RaidIncomingTickTime }





	else
		raid.attackData.attackPosition = raid.center
	end

	local success, result = sm.physics.raycast( raid.attackData.attackPosition + sm.vec3.new( 0, 0, 126 ), raid.attackData.attackPosition - sm.vec3.new( 0, 0, 126 ), nil, sm.physics.filter.terrainSurface, cropHarvestable:getWorld() )
	if success then
		raid.attackData.attackPosition = result.pointWorld
	end

	sm.storage.save( STORAGE_CHANNEL_RAIDMANAGER, self.sv.saved )
	self.sv.synchToClients = true
	return raid.key
end

function RaidManager.Sv_GetCropArea( worldId, raidKey )
	if g_raidManager then
		return g_raidManager:sv_getCropArea( worldId, raidKey )
	end
	return nil
end

function RaidManager.sv_getCropArea( self, worldId, raidKey )
	local raids = self.sv.saved.worldRaids[worldId]
	local raid = raids and raids[raidKey]
	local area = raid and raid.cropArea
	if area == nil then
		return nil
	end
	return area.center, area.radius
end

function RaidManager.Sv_GetCropRaidKey( cropHarvestable )
	if g_raidManager then
		return g_raidManager:sv_getCropRaidKey( cropHarvestable )
	end
	return nil
end

function RaidManager.sv_getCropRaidKey( self, cropHarvestable )
	local worldId = cropHarvestable:getWorld().id
	for raidKey, raid in pairs( self.sv.saved.worldRaids[worldId] or {} ) do
		for id, _ in pairs( raid.existingCrops ) do
			if id == cropHarvestable.id then
				return raidKey
			end
		end
	end
	return nil
end

-- raidKey: the key the plant was given when the raid adopted it
function RaidManager.Sv_CropDestroyed( cropHarvestable, raidKey )
	if g_raidManager then
		g_raidManager:sv_cropDestroyed( cropHarvestable, raidKey )
	end
end

function RaidManager.sv_cropDestroyed( self, cropHarvestable, raidKey )
	local worldId = cropHarvestable:getWorld().id
	local raids = self.sv.saved.worldRaids[worldId]
	local raid = raids and raids[raidKey]
	if not raid then
		return
	end
	raid.existingCrops[cropHarvestable.id] = nil
	for i, pos in ipairs( raid.cropPositions ) do
		if pos == cropHarvestable.worldPosition then
			table.remove( raid.cropPositions, i )
			break
		end
	end
	if not IsEmptyTable( raid.cropPositions ) and not raid.timeoutTick then
		raid.attackData.attackPosition = sm.util.geometricMedian( raid.cropPositions, nil, 12 )
		local success, result = sm.physics.raycast( raid.attackData.attackPosition + sm.vec3.new( 0, 0, 126 ), raid.attackData.attackPosition - sm.vec3.new( 0, 0, 126 ), nil, sm.physics.filter.terrainSurface, cropHarvestable:getWorld() )
		if success then
			raid.attackData.attackPosition = result.pointWorld
		end
	end
	if IsEmptyTable( raid.existingCrops ) then
		sm.event.sendToScriptableObject( self.scriptableObject, "sv_e_noCropsLeft", { worldId = worldId, raidKey = raidKey }, sm.event.types.instant )
	end
	if not raid.attackData.groupSpawns then
		for i,orderData in ipairs( raid.plantingOrder ) do
			if cropHarvestable.uuid == orderData.uid and cropHarvestable.worldPosition == orderData.position then
				table.remove( raid.plantingOrder, i )
				break
			end
		end
		local value = 0
		for _,orderData in ipairs( raid.plantingOrder ) do
			value = value + GetPlantValue( tostring( orderData.uid ) )
		end
		raid.value = value
		raid.maxValue = raid.value
		raid.level = GetRaidLevel( raid.value )





	end
	sm.storage.save( STORAGE_CHANNEL_RAIDMANAGER, self.sv.saved )
	self.sv.synchToClients = true
end

function RaidManager.sv_navMeshCreated( self, world, x, y, params )
	local finished = self.sv.finishedNavMeshLoads[params.key]
	if finished then -- nil once the raid has released its handles
		self.sv.finishedNavMeshLoads[params.key] = finished + 1
	end
end

function RaidManager.sv_releaseActiveLoadHandles( self, raidKey )
	local handles = self.sv.activeRaidLoadHandles[raidKey]
	if handles then
		for _,handle in ipairs( handles ) do
			handle:release()
		end
		self.sv.activeRaidLoadHandles[raidKey] = nil
	end
end

function RaidManager.sv_releaseSpawnPointHandles( self, raidKey )
	local handles = self.sv.navmeshHandles[raidKey]
	if handles then
		for _,handle in ipairs( handles ) do
			handle:release()
		end
	end
	self.sv.navmeshHandles[raidKey] = nil
	local cellHandles = self.sv.spawnPointCellHandles[raidKey]
	if cellHandles then
		for _,handle in ipairs( cellHandles ) do
			handle:release()
		end
		self.sv.spawnPointCellHandles[raidKey] = nil
	end
	self.sv.finishedNavMeshLoads[raidKey] = nil
	self.sv.raidPaths[raidKey] = nil
	self.sv.raidsPathGenerationData[raidKey] = nil
end

-- Called by the world right after createUnit, which only queues the unit, so worldId and uuid come from the caller.
function RaidManager.Sv_AddRaider( raidKey, worldId, unit, uuid, spawnPos )
	if g_raidManager then
		g_raidManager:sv_addRaider( raidKey, worldId, unit, uuid, spawnPos )
	end
end

function RaidManager.sv_addRaider( self, raidKey, worldId, unit, uuid, spawnPos )
	local raids = self.sv.saved.worldRaids[worldId] or {}
	local raid = raids[raidKey]
	if raid then
		raid.raiders = raid.raiders or {}
		raid.raiders[unit.id] = { unit = unit, uuid = uuid, spawnPos = spawnPos }
		sm.storage.save( STORAGE_CHANNEL_RAIDMANAGER, self.sv.saved )
	end
end

function RaidManager.Sv_RemoveRaider( raidKey, unit )
	if g_raidManager then
		g_raidManager:sv_removeRaider( raidKey, unit )
	end
end

function RaidManager.sv_removeRaider( self, raidKey, unit )
	local worldId = unit.character:getWorld().id
	local raids = self.sv.saved.worldRaids[worldId] or {}
	local raid = raids[raidKey]
	if raid then
		if raid.raiders then
			if raid.raiders[unit.id] then
				raid.value = raid.value - ( raid.maxValue / raid.totalEnemyCount )
			end
			raid.raiders[unit.id] = nil
			if IsEmptyTable( raid.raiders ) then
				raid.raiders = nil
			end
			if raid.enemiesLeft == nil then
				raid.enemiesLeft = raid.totalEnemyCount
			end
			raid.enemiesLeft = raid.enemiesLeft - 1



			if raid.enemiesLeft <= 0 and raid.lastSpawnTick <= sm.game.getCurrentTick() - raid.attackStartTick then -- every group has spawned and every raider is defeated
				sm.event.sendToScriptableObject( self.scriptableObject, "sv_e_raidSurvived", { worldId = worldId, raidKey = raidKey }, sm.event.types.instant )
			end
			sm.storage.save( STORAGE_CHANNEL_RAIDMANAGER, self.sv.saved )
			self.sv.synchToClients = true
		end
	else
		self:sv_releaseFleeingRaider( worldId, raidKey, unit.id )
	end
end

-- The crops outlasted the attack, either because every raider was defeated or because the attack time ran out.
-- Gives the rewards and notifies the players, then closes the raid. Its plants notice the raid is gone and may mature.
function RaidManager.sv_raidSurvived( self, raid, worldId, raidKey )
	local hasCarrots = false
	local hasBananas = false
	for _,harvestable in pairs( raid.existingCrops ) do
		if sm.exists( harvestable ) then
			if harvestable.uuid == hvs_growing_carrot then
				hasCarrots = true
			elseif harvestable.uuid == hvs_growing_banana then
				hasBananas = true
			end
		end
	end
	if QuestManager.Sv_IsQuestComplete( "quest_mystery_call" ) then
		if hasCarrots then
			DialogManager.Sv_PlayNamedBondBuilder( "carrot_raid" )
		end
		if hasBananas then
			DialogManager.Sv_PlayNamedBondBuilder( "banana_raid" )
		end
		
	end
	if worldId then
		for _,player in ipairs( sm.player.getAllPlayers() ) do
			if sm.exists( player.character ) and player.character:getWorld().id == worldId then
				sm.event.sendToPlayer( player, "sv_e_raidCompleted" )
			end
		end
	end
	
	if (raid.level >= 5) then
		sm.achievement.addi("005aaeb2-4562-40a4-ae14-2b7881b42e7e", 1, nil)
	end
	sm.achievement.addi("0524f0c7-040d-40d8-be90-b405fd63bd64", 1, nil)

	self:sv_closeRaid( raid, worldId, raidKey )
end

-- Chat command
function RaidManager.Sv_CancelRaids( world )
	if g_raidManager then
		g_raidManager:sv_cancelRaids( world )
	end
end

function RaidManager.sv_cancelRaids( self, world )
	local worldId = world.id
	local raids = self.sv.saved.worldRaids[worldId] or {}
	local raidKeys = {}
	for raidKey in pairs( raids ) do
		raidKeys[#raidKeys+1] = raidKey
	end
	for _, raidKey in ipairs( raidKeys ) do
		local raid = raids[raidKey]
		for _,harvestable in pairs( raid.existingCrops ) do
			if sm.exists( harvestable ) then
				sm.event.sendToHarvestable( harvestable, "sv_e_raidNuke" )
			end
		end
		for unitId,raider in pairs( raid.raiders or {} ) do
			if sm.exists( raider.unit ) then
				raider.unit:destroy()
			else
				sm.unit.forceDestroy( raider.unit )
			end
			self.sv.raiderMissingTicks[unitId] = nil
		end
		raid.raiders = nil -- already destroyed, so none of them should flee
		self:sv_closeRaid( raid, worldId, raidKey )
	end
	self.sv.saved.worldRaids[worldId] = nil
	self.sv.saved.fleeingRaids[worldId] = nil
	sm.storage.save( STORAGE_CHANNEL_RAIDMANAGER, self.sv.saved )
	self.sv.synchToClients = true
end

function RaidManager.sv_e_raidSurvived( self, data )
	local raids = self.sv.saved.worldRaids[data.worldId]
	local raid = raids and raids[data.raidKey]
	if raid then
		self:sv_raidSurvived( raid, data.worldId, data.raidKey )
	end
end

function RaidManager.sv_e_noCropsLeft( self, data )
	local raids = self.sv.saved.worldRaids[data.worldId]
	local raid = raids and raids[data.raidKey]
	if raid then
		self:sv_closeRaid( raid, data.worldId, data.raidKey )
	end
end

function RaidManager.sv_getFleeingRaid( self, worldId, raidKey )
	local fleeingRaids = self.sv.saved.fleeingRaids[worldId]
	return fleeingRaids and fleeingRaids[raidKey]
end

-- The record is dropped once none of its raiders remain.
function RaidManager.sv_releaseFleeingRaider( self, worldId, raidKey, unitId )
	local fleeingRaid = self:sv_getFleeingRaid( worldId, raidKey )
	if fleeingRaid then
		fleeingRaid.raiders[unitId] = nil
		if IsEmptyTable( fleeingRaid.raiders ) then
			self.sv.saved.fleeingRaids[worldId][raidKey] = nil
		end
		self.sv.isDirty = true
	end
end

-- Removes the raid. A raider that is left flees from it when it loads; the ones that never load are destroyed when the fleeing record expires.
function RaidManager.sv_closeRaid( self, raid, worldId, raidKey )
	if raid.raiders then
		local raiders = {}
		for unitId, raider in pairs( raid.raiders ) do
			raiders[unitId] = { unit = raider.unit, spawnPos = raider.spawnPos }
			self.sv.raiderMissingTicks[unitId] = nil
		end
		self.sv.saved.fleeingRaids[worldId] = self.sv.saved.fleeingRaids[worldId] or {}
		self.sv.saved.fleeingRaids[worldId][raidKey] = {
			center = raid.center,
			raiders = raiders, -- unit id -> { unit, spawnPos }
			expireTick = sm.game.getCurrentTick() + RAIDER_FLEE_TICK_DURATION
		}
	end
	self.sv.saved.worldRaids[worldId][raidKey] = nil
	self.sv.isDirty = true
	self.sv.synchToClients = true
	self:sv_releaseActiveLoadHandles( raidKey )
	self:sv_releaseSpawnPointHandles( raidKey )
end

-- False while the manager is not up, so a raider is never mistaken for being in a finished raid.
function RaidManager.Sv_IsRaidOver( worldId, raidKey )
	if g_raidManager then
		local raids = g_raidManager.sv.saved.worldRaids[worldId]
		return raids == nil or raids[raidKey] == nil
	end
	return false
end

function RaidManager.Sv_GetRaidCenter( worldId, raidKey )
	if g_raidManager then
		local raids = g_raidManager.sv.saved.worldRaids[worldId]
		local raid = raids and raids[raidKey]
		if raid then
			return raid.center
		end
		local fleeingRaid = g_raidManager:sv_getFleeingRaid( worldId, raidKey )
		return fleeingRaid and fleeingRaid.center
	end
	return nil
end

function RaidManager.Sv_GetRaiderSpawnPosition( worldId, raidKey, unit )
	if g_raidManager then
		local raids = g_raidManager.sv.saved.worldRaids[worldId]
		local raid = raids and raids[raidKey]
		if raid then
			local raider = raid.raiders and raid.raiders[unit.id]
			return raider and raider.spawnPos
		end
		local fleeingRaid = g_raidManager:sv_getFleeingRaid( worldId, raidKey )
		local raider = fleeingRaid and fleeingRaid.raiders[unit.id]
		return raider and raider.spawnPos
	end
	return nil
end

function RaidManager.Sv_OnWorldFixedUpdate( world )
	if g_raidManager then
		g_raidManager:sv_onWorldFixedUpdate( world )
	end
end

function RaidManager.sv_onWorldFixedUpdate( self, world )
	local worldId = world.id
	local currentTick = sm.game.getCurrentTick()
	local raids = self.sv.saved.worldRaids[worldId] or {}

	local fleeingRaids = self.sv.saved.fleeingRaids[worldId]
	if fleeingRaids then
		for raidKey, fleeingRaid in pairs( fleeingRaids ) do
			if currentTick >= fleeingRaid.expireTick then
				-- This is the final removal of raiders that were unloaded at the time of the raid's expiration.
				-- It must happen here because during game load 
				for _, raider in pairs( fleeingRaid.raiders ) do
					if not sm.exists( raider.unit ) then
						sm.unit.forceDestroy( raider.unit )
					end
				end
				fleeingRaids[raidKey] = nil
				self.sv.isDirty = true
			end
		end
	end

	-- A raid with no crop positions left has nothing to attack
	local cropless = {}
	for raidKey, raid in pairs( raids ) do
		if IsEmptyTable( raid.cropPositions ) then
			cropless[#cropless+1] = raidKey
		end
	end
	for _, raidKey in ipairs( cropless ) do
		self:sv_closeRaid( raids[raidKey], worldId, raidKey )
	end

	for raidKey, raid in pairs( raids ) do
		-- The timeline runs whether or not a player is near. Raiders spawned in unloaded cells are unloaded by the unit manager.
		local elapsedTicks
		if raid.attackData.groupSpawns then
			elapsedTicks = currentTick - raid.attackStartTick

			if raid.attackData.spawnPositions then
				for _,group in ipairs( raid.attackData.groupSpawns ) do
					if elapsedTicks >= group.tickDelay and not group.isSpawned then
						local spawnPos = raid.attackData.spawnPositions[( group.spawnIndex - 1 ) % #raid.attackData.spawnPositions + 1].path
						local raiders = {}
						for _,enemyData in ipairs( group.enemyList ) do
							for _ = 1, enemyData.quantity do
								raiders[#raiders+1] = RaidEnemySubTypeRandomizer( enemyData.uuid )
							end
						end
						group.isSpawned = true
						sm.event.sendToWorld( world, "sv_e_spawnRaiders", { raidKey = raidKey, attackPos = raid.center, raiders = raiders, spawnPos = spawnPos, raiderPositions = group.raiderPositions } )
					end
				end
			end
		end

		if HasNearbyPlayer( raid.center, self.sv.activeRaidLoadHandles[raidKey] ~= nil ) then
			if self.sv.activeRaidLoadHandles[raidKey] == nil then
				self.sv.activeRaidLoadHandles[raidKey] = {}
				local range = math.floor( GetRaidCellRange() )
				local cellX = math.floor( raid.center.x / 64 )
				local cellY = math.floor( raid.center.y / 64 )
				for x = -range, range do
					for y = -range, range do
						self.sv.activeRaidLoadHandles[raidKey][#self.sv.activeRaidLoadHandles[raidKey]+1] = world:loadCellWithHandle( cellX + x, cellY + y )
					end
				end
			end

			if raid.raiders and currentTick % 40 == 0 then
				-- try respawning missing raiders. Missing time only accumulates here, while a player is near.
				local missingTicks = self.sv.raiderMissingTicks
				local toRespawn = {}
				for unitId, raider in pairs( raid.raiders ) do
					if sm.exists( raider.unit ) then
						missingTicks[unitId] = nil
					elseif raider.spawnPos then
						missingTicks[unitId] = ( missingTicks[unitId] or 0 ) + 40
						if missingTicks[unitId] >= RaiderMissingRespawnTicks
						and IsPositionCellLoaded( world, raider.spawnPos ) and IsPositionCellLoaded( world, raid.center ) then
							toRespawn[#toRespawn+1] = unitId
						end
					end
				end

				if #toRespawn > 0 then
					local respawnUuids = {}
					local respawnPositions = {}
					for i, unitId in ipairs( toRespawn ) do
						local raider = raid.raiders[unitId]
						sm.unit.forceDestroy( raider.unit )
						raid.raiders[unitId] = nil -- cleared but enemiesLeft unchanged
						missingTicks[unitId] = nil
						respawnUuids[i] = raider.uuid
						respawnPositions[i] = raider.spawnPos
					end
					sm.event.sendToWorld( world, "sv_e_spawnRaiders", { raidKey = raidKey, attackPos = raid.center, raiders = respawnUuids, raiderPositions = respawnPositions } )
					self.sv.isDirty = true
				end
			end

			-- Only time spent near the raid counts, so a player who stays away never has the crops outlast the attack
			if raid.timeoutTick and elapsedTicks >= raid.lastSpawnTick then
				raid.timeoutProgress = ( raid.timeoutProgress or 0 ) + 1
				if raid.timeoutProgress >= RaidTimeoutTickTime then -- the crops outlasted the attack
					self:sv_raidSurvived( raid, worldId, raidKey )
				end
			end

		else
			self:sv_releaseActiveLoadHandles( raidKey )
		end

		-- The attack starts and its spawn points are generated whether or not a player is near, so the drops are on time
		if raid.attackData.attackTick and currentTick >= raid.attackData.attackTick then
			-- Prepare raid groups
			GetRaidEnemies( raid )
			raid.cropArea = ComputeCropArea( raid )
			raid.attackStartTick = currentTick



			self.sv.isDirty = true
			self.sv.synchToClients = true

			raid.attackData.attackTick = nil
			raid.needsSpawnPoints = true
		end

		if raid.needsSpawnPoints and not self.sv.navmeshHandles[raidKey] then
			self.sv.navmeshHandles[raidKey] = {}
			self.sv.spawnPointCellHandles[raidKey] = {}
			self.sv.finishedNavMeshLoads[raidKey] = 0
			local cellX = math.floor( raid.center.x / 64 )
			local cellY = math.floor( raid.center.y / 64 )
			local range = math.floor( GetRaidCellRange() )
			for x = -range, range do
				for y = -range, range do
					self.sv.spawnPointCellHandles[raidKey][#self.sv.spawnPointCellHandles[raidKey]+1] = world:loadCellWithHandle( x + cellX, y + cellY )
					self.sv.navmeshHandles[raidKey][#self.sv.navmeshHandles[raidKey]+1] = world:loadNavMeshWithHandle( x + cellX, y + cellY, "sv_navMeshCreated", { key = raidKey }, g_raidManager )
				end
			end
		end

		if self.sv.navmeshHandles[raidKey] and self.sv.finishedNavMeshLoads[raidKey] == #self.sv.navmeshHandles[raidKey] then
			self.sv.raidPaths[raidKey] = {}
			self.sv.raidsPathGenerationData[raidKey] = { rotation = math.rad( math.random() * 360 ), currentIndex = 1 }
			self.sv.finishedNavMeshLoads[raidKey] = nil
		end

		-- Generate 1 path per tick until enough spawn points are gathered
		if self.sv.raidPaths[raidKey] then
			self.sv.raidPaths[raidKey][#self.sv.raidPaths[raidKey]+1] = CreateRaidPath( raid.center, world, self.sv.raidsPathGenerationData[raidKey].rotation, self.sv.raidsPathGenerationData[raidKey].currentIndex )
			self.sv.raidsPathGenerationData[raidKey].currentIndex = self.sv.raidsPathGenerationData[raidKey].currentIndex + 1
			if #self.sv.raidPaths[raidKey] == RAID_SAMPLE_POINT_COUNT then
				local spawnPositions = FilterAndSelectPoints( self.sv.raidPaths[raidKey], world, raid.center )
				if IsEmptyTable( spawnPositions ) then
					-- Exploitable, since the plants mature without a fight, but better than crashing all raids.
					sm.log.error( "Raid has no reachable spawn position and is closed: "..raidKey )
					self:sv_closeRaid( raid, worldId, raidKey )
				else
					raid.attackData.spawnPositions = spawnPositions
					shuffle( raid.attackData.spawnPositions )
					raid.needsSpawnPoints = false
					self.sv.isDirty = true
					self.sv.synchToClients = true

					-- Precompute each group's raider spread while the navmesh is still loaded, so spawning later doesn't depend on it
					for _,group in ipairs( raid.attackData.groupSpawns ) do
						local groupSpawnPos = raid.attackData.spawnPositions[( group.spawnIndex - 1 ) % #raid.attackData.spawnPositions + 1].path
						local raiderCount = 0
						for _,enemyData in ipairs( group.enemyList ) do
							raiderCount = raiderCount + enemyData.quantity
						end
						group.raiderPositions = GenerateRaiderSpawnPositions( world, groupSpawnPos, raiderCount )
					end

					self:sv_releaseSpawnPointHandles( raidKey )
				end
			end
		end
	end
end


function RaidManager.Sv_GetClosestPlayerInRaid( worldId, raidKey, position )
	if g_raidManager then
		return g_raidManager:sv_getClosestPlayerInRaid( worldId, raidKey, position )
	end
	return nil
end

function RaidManager.sv_getClosestPlayerInRaid( self, worldId, raidKey, position )
	local closestCharacter = nil
	local bestRange = math.huge
	local raids = self.sv.saved.worldRaids[worldId] or {}
	if raids[raidKey] then
		for _,player in ipairs( sm.player.getAllPlayers() ) do
			local character = player:getCharacter()
			if character then
				if ( character.worldPosition - raids[raidKey].center ):length2() <= ( RAID_RADIUS * RAID_RADIUS ) then
					local distSqr = ( position - character.worldPosition ):length2()
					if distSqr <= bestRange then
						closestCharacter = character
						bestRange = distSqr
					end
				end
			end
		end
	end
	return closestCharacter
end

--[[ Client ]]

function RaidManager.client_onCreate( self )
	g_raidManagerClient = self
	self.cl = {}
	self.cl.worldRaids = {}
	self.cl.heldPlant = nil
	self.cl.localPlayerPlantingGui = nil
	self.cl.fadeTimer = 0
	self.cl.oscillationTimer = 0
end

function RaidManager.Cl_ShowPlantingOutcome( uuid )
	if g_raidManagerClient then
		g_raidManagerClient:cl_showPlantingOutcome( uuid )
	end
end

function RaidManager.Cl_HidePlantingOutcome()
	if g_raidManagerClient then
		g_raidManagerClient:cl_showPlantingOutcome( nil )
	end
end

function RaidManager.cl_showPlantingOutcome( self, uuid )
	self.cl.heldPlant = uuid
	self:cl_triggerGuiRedraw()
end

function RaidManager.cl_triggerGuiRedraw( self )
	local worldId = sm.localPlayer.getPlayer().character:getWorld().id
	local raids = self.cl.worldRaids[worldId] or {}
	for _, raid in pairs( raids ) do
		raid.cl.previousShowGui = false
	end
end

function RaidManager.client_onClientDataUpdate( self, clientData, channel )
	if channel == 1 then
		-- Add/Update worldRaids
		local updatedWorldRaids = {}
		for worldId, raids in pairs( clientData ) do
			updatedWorldRaids[worldId] = {}
			local prevRaids = self.cl.worldRaids[worldId] or {}
			for raidId, raidSync in pairs( raids ) do
				-- Move existing client raid data/gui
				local updatedRaid = { raidSync = {}, cl = {} }
				if prevRaids[raidId] then
					updatedRaid.cl = prevRaids[raidId].cl or {}
					prevRaids[raidId] = nil
				end
				-- Set raid data from server
				updatedRaid.raidSync = raidSync
				updatedRaid.cl.previousShowGui = false
				if updatedRaid.cl.previousValue == nil and updatedRaid.cl.fromValue == nil then
					updatedRaid.cl.fromValue = 0
					updatedRaid.cl.barMoveTimer = 0
					updatedRaid.cl.barDelayTimer = 0
					updatedRaid.cl.alphaSwapTimer = 0
				elseif updatedRaid.cl.fromValue == nil then
					updatedRaid.cl.fromValue = updatedRaid.cl.previousValue
					updatedRaid.cl.barMoveTimer = 0
					updatedRaid.cl.barDelayTimer = 0
					updatedRaid.cl.alphaSwapTimer = 0
				end
				updatedRaid.cl.previousValue = raidSync.value
				updatedWorldRaids[worldId][raidId] = updatedRaid
			end
		end

		-- Cleanup leftover client raid data
		for _, raids in pairs( self.cl.worldRaids ) do
			for _, raid in pairs( raids ) do
				if raid.cl.raidStatusJsonGui then
					raid.cl.raidStatusJsonGui:close()
					raid.cl.raidStatusJsonGui = nil
				end
				if raid.cl.markerEffectNear then
					raid.cl.markerEffectNear:destroy()
					raid.cl.markerEffectNear = nil
				end
				if raid.cl.markerEffectFar then
					raid.cl.markerEffectFar:destroy()
					raid.cl.markerEffectFar = nil
				end
				if raid.cl.groupDrops then
					for _,drop in pairs( raid.cl.groupDrops ) do
						if g_compassHud then
							g_compassHud:compassRemoveIcon( drop.compass.name )
						end
						if drop.effects then
							if sm.exists( drop.effects.pod ) then
								drop.effects.pod:destroy()
							end
							if sm.exists( drop.effects.impact ) then
								drop.effects.impact:destroy()
							end
						end
					end
					raid.cl.groupDrops = nil
				end
				if g_compassHud then
					g_compassHud:compassRemoveIcon( raid.raidSync.key )
				end
			end
		end
		self.cl.updateGui = true
		self.cl.worldRaids = updatedWorldRaids
	end
end

function RaidManager.Cl_OnWorldUpdate( worldId, deltaTime )
	if g_raidManagerClient then
		g_raidManagerClient:cl_onWorldUpdate( worldId, deltaTime )
	end
end

-- Nil once the raid is gone
function RaidManager.Cl_GetRaidCenter( worldId, raidKey )
	if g_raidManagerClient then
		local raids = g_raidManagerClient.cl.worldRaids[worldId]
		local raid = raids and raids[raidKey]
		return raid and raid.raidSync.center
	end
	return nil
end

-- Gui and effects

local function GetCountdownText( raid, currentTick )
	local numericalValue = math.max( 0, math.floor( ( raid.raidSync.attackData.attackTick - currentTick ) / 40 ) )
	local stringValue = ( numericalValue < 10 ) and ( "0"..tostring( numericalValue ) ) or tostring( numericalValue )
	return stringValue, numericalValue
end

local function Cl_TryPlayCountdownEffect( raid, numericalValue )
	if raid.cl.previousCountdownValue ~= numericalValue then
		raid.cl.previousCountdownValue = numericalValue
		if RaidCountdownEffectValues[numericalValue] then
			sm.effect.playEffect( "audio:event:/ui/raid/countdown", sm.vec3.zero() )
		elseif numericalValue == 0 then
			sm.effect.playEffect( "audio:event:/ui/raid/countdown_end", sm.vec3.zero() )
			raid.cl.previousCountdownValue = nil
		end
	end
end

function RaidManager.cl_handleGuiFade( self, anyRaidControllingGui, deltaTime )
	if self.cl.localPlayerPlantingGui then
		if not anyRaidControllingGui then
			if RaidPanelGui.index.RaidPanel.Alpha > 0 then
				local newAlpha = lerp( 1.0, 0.0, self.cl.fadeTimer / GuiFadeOutDuration )
				RaidPanelGui.index.RaidPanel.Alpha = newAlpha
				self.cl.fadeTimer = self.cl.fadeTimer + deltaTime
			else
				self.cl.localPlayerPlantingGui:close()
				self.cl.localPlayerPlantingGui = nil
				self.cl.fadeTimer = 0
			end
		else
			if RaidPanelGui.index.RaidPanel.Alpha < 1 then
				local newAlpha = lerp( 0.0, 1.0, self.cl.fadeTimer / GuiFadeInDuration )
				RaidPanelGui.index.RaidPanel.Alpha = newAlpha
				self.cl.fadeTimer = self.cl.fadeTimer + deltaTime
			else
				self.cl.fadeTimer = 0
			end
		end
		if self.cl.localPlayerPlantingGui then
			self.cl.localPlayerPlantingGui:render( RaidPanelGui.root )
		end
	end
end

function RaidManager.cl_onWorldUpdate( self, worldId, deltaTime )
	local currentTick = sm.game.getServerTick()
	local raids = self.cl.worldRaids[worldId] or {}
	local closestRaidId
	local closestRaidDistance2 = math.huge
	local anyRaidControllingGui = false
	local myPlayer = sm.localPlayer.getPlayer()
	local myCharacter = myPlayer and myPlayer.character or nil
	local myPosition = sm.exists( myCharacter ) and myCharacter.worldPosition or nil

	for raidId, raid in pairs( raids ) do
		-- Update gui position
		if raid.cl.guiWorldPosition == nil then
			raid.cl.guiWorldPosition = raid.raidSync.attackData.attackPosition
		else
			raid.cl.previousPosition = raid.cl.guiWorldPosition
			local pos = raid.raidSync.attackData.attackPosition
			raid.cl.guiWorldPosition = magicPositionInterpolation( raid.cl.guiWorldPosition, pos, deltaTime, 1/6 )
		end

		local myDistance2 = myPosition and ( myPosition - raid.raidSync.center ):length2() or math.huge
		local insideRaidArea = RaidManager.IsWithinRaidRadius( myDistance2, raid.cl.insideRaidArea )
		raid.cl.insideRaidArea = insideRaidArea

		if myDistance2 < closestRaidDistance2 then
			closestRaidDistance2 = myDistance2
			closestRaidId = raidId
		end
		local activeAttack = raid.raidSync.attackData.spawnPositions ~= nil
		local showInfo = insideRaidArea and raid.cl.isClosest and raid.raidSync.value > 0
		local countdownStarted = raid.raidSync.attackData.attackTick and currentTick > raid.raidSync.attackData.attackTick - RaidIncomingTickTime + RaidResetOnPlantTickTime
		-- The far marker stays up for the whole raid; the near marker with the countdown only shows during the countdown
		local showMarker = countdownStarted or raid.raidSync.timeoutTick ~= nil
		local showNearMarker = showInfo and countdownStarted
		local showFarMarker = showMarker and not insideRaidArea
		local showCompassDrops = insideRaidArea and raid.cl.isClosest and raid.raidSync.attackData.spawnPositions
		local showRaidDropEffects = raid.raidSync.level > 1 and raid.raidSync.attackData.spawnPositions and raid.raidSync.timeoutTick

		if not raid.cl.notificationShown and raid.raidSync.attackData.attackTick
		and currentTick >= raid.raidSync.attackData.attackTick - RaidIncomingTickTime + RaidResetOnPlantTickTime then
			NotificationManager.Cl_AddRaidWarningNotification( "#{RAID_WARNING_MESSAGE}" )
			raid.cl.notificationShown = true
		end

		anyRaidControllingGui = anyRaidControllingGui or insideRaidArea

		-- Drops follow the server's absolute ticks and play for any client within a long radius of the raid
		local dropsInRange = myDistance2 <= DropEffectRadius * DropEffectRadius

		-- The countdown sounds play within the same long radius, not only where the near marker's numbers can be read
		if dropsInRange and countdownStarted then
			local _, secondsLeft = GetCountdownText( raid, currentTick )
			Cl_TryPlayCountdownEffect( raid, secondsLeft )
		end
		if showRaidDropEffects and ( raid.cl.groupDrops or dropsInRange ) then
			if raid.cl.groupDrops == nil then
				raid.cl.groupDrops = {}
				for i,groupData in ipairs( raid.raidSync.attackData.groupSpawns ) do
					local position = raid.raidSync.attackData.spawnPositions[( groupData.spawnIndex - 1 ) % #raid.raidSync.attackData.spawnPositions + 1].path
					local direction = ( position - raid.raidSync.attackData.attackPosition ):safeNormalize( sm.vec3.new( 0, 0, 1 ) )
					local first = groupData.tickDelay == raid.raidSync.attackData.groupSpawns[1].tickDelay
					local fromPos = first and position - direction * DropEffectTravelDistance or position + direction * DropEffectTravelDistance
					-- compass: the icon that travels to the drop point; effects: the pod and impact effects, created when the drop starts
					local compass = { active = false, name = raid.raidSync.key..tostring( i ), fromPos = fromPos, toPos = position }
					raid.cl.groupDrops[i] = { dropStartTick = nil, effects = nil, compass = compass }
					if g_compassHud then
						g_compassHud:compassAddIcon( compass.name, "icon_compass_dropcargo.png", true, 32 )
						g_compassHud:compassSetIconWorldPosition( compass.name, fromPos )
						g_compassHud:compassSetIconStacking( compass.name, false )
					end
				end
			end
			for i,groupData in ipairs( raid.raidSync.attackData.groupSpawns ) do
				local drop = raid.cl.groupDrops[i]
				local dropStartTick = groupData.dropStartTick
				if dropsInRange and currentTick >= dropStartTick and not drop.dropStartTick then
					-- Fast-forwards audio and tracks when the drop began before the client got here (e.g. after reload)
					local elapsedTicks = currentTick - dropStartTick
					local effectStartTime = elapsedTicks / 40
					local spawnPosition = raid.raidSync.attackData.spawnPositions[( groupData.spawnIndex - 1 ) % #raid.raidSync.attackData.spawnPositions + 1]
					local spawnPoint = spawnPosition.path
					local material = spawnPosition.material
					if material == "" then
						material = sm.physics.getGroundMaterial( spawnPoint )
					end
					local direction = spawnPoint - raid.raidSync.attackData.attackPosition
					direction.z = 0
					-- Drops that land together with the first come in from the attack side, later ones from the opposite side
					local isOpeningDrop = ( groupData.tickDelay - raid.raidSync.attackData.groupSpawns[1].tickDelay ) <= MultiDropRandomOffset * 40
					local facing = isOpeningDrop and direction or -direction
					local rotation = sm.vec3.getRotation( sm.vec3.new( 0, 1, 0 ), facing:safeNormalize( sm.vec3.new( 1, 0, 0 ) ) )
					local effect = sm.effect.createEffect( isOpeningDrop and "Raidrop01 - Droppod" or "Raidrop02 - Droppod" )
					effect:setPosition( spawnPoint )
					effect:setRotation( rotation )
					effect:setParameter( "material", sm.shape.material.metal )
					effect:start( effectStartTime )
						
					local impactEffect = sm.effect.createEffect( "Raidrop01 - DroppodImpact" )
					impactEffect:setPosition( spawnPoint )
					impactEffect:setRotation( rotation )
					impactEffect:setParameter( "material", sm.physics.getMaterialId( material ) )
					impactEffect:start( effectStartTime )
					drop.effects = { pod = effect, impact = impactEffect, timer = effectStartTime }
					drop.dropStartTick = dropStartTick
					if elapsedTicks < MarkerTickLifetime then
						drop.compass.active = true
						if g_compassHud and showCompassDrops then
							g_compassHud:setVisible( drop.compass.name, true )
							g_compassHud:compassPingMarker( drop.compass.name, "Gui - Raid_Arrows01_loop" )
						end
					end
				elseif currentTick >= dropStartTick + MarkerTickLifetime and drop.compass.active then
					drop.compass.active = false
					if g_compassHud then
						g_compassHud:setVisible( drop.compass.name, false )
					end
				end
			end
			for _, drop in ipairs( raid.cl.groupDrops ) do
				local compass = drop.compass
				if compass.active and g_compassHud then
					local visible = showCompassDrops and true or false
					g_compassHud:setVisible( compass.name, visible )
					if visible and not compass.movementDone then
						local fraction = math.min( ( currentTick - drop.dropStartTick ) / 40 / DropEffectDuration, 1.0 )
						compass.movementDone = fraction >= 1.0
						g_compassHud:compassSetIconWorldPosition( compass.name, lerp( compass.fromPos, compass.toPos, fraction ) )
					end
				end
			end
			for _, drop in ipairs( raid.cl.groupDrops ) do
				local effects = drop.effects
				if effects and effects.pod:isPlaying() then
					effects.timer = effects.timer + deltaTime
					if effects.timer >= DoorDissolveDelay then
						local fraction = math.min( ( effects.timer - DoorDissolveDelay ) / DoorDissolveDuration , 1.0 )
						effects.pod:setParameter( "pose2", lerp( 0.5, 1, fraction ) )
					end
				end
			end
		end

		if showInfo and ( not raid.cl.previousShowGui and ( self.cl.updateGui or raid.cl.raidStatusJsonGui == nil ) or ( raid.cl.barMoveTimer ~= nil ) ) then
			if raid.cl.raidStatusJsonGui == nil then
				raid.cl.raidStatusJsonGui = sm.jsonGui.createGui( { isHud = true, needsCursor = false, isInteractive = false } )
				raid.cl.guiCreationTick = currentTick
				local newAlpha = GetRaidIsSuper( raid.raidSync.value ) and 0 or 1
				RaidPanelGui.index.RaidBar.Alpha = newAlpha
				for _,data in ipairs( RaidPanelGui.index.RaidBar.Childs ) do
					data.Alpha = newAlpha
				end
			end
			if RaidPanelGui.index.RaidPanel.Alpha == 0 then
				RaidPanelGui.index.RaidPanel.Alpha = 1
			end
			RaidPanelGui.index.RaidBarHighlight.Visible = false
			RaidPanelGui.index.RaidBarHighlightSuper.Visible = false
			if raid.cl.barMoveTimer and raid.cl.barMoveTimer == 0 then
				RaidPanelGui.index.RaidBarHighlightEffect.Effects[1].ResetPlayOnce = true
				RaidPanelGui.index.RaidBarHighlightSuperEffect.Effects[1].ResetPlayOnce = true
			else
				RaidPanelGui.index.RaidBarHighlightEffect.Effects[1].ResetPlayOnce = false
				RaidPanelGui.index.RaidBarHighlightEffect.Effects[1].PlayState = "Stopped"
				RaidPanelGui.index.RaidBarHighlightSuperEffect.Effects[1].ResetPlayOnce = false
				RaidPanelGui.index.RaidBarHighlightSuperEffect.Effects[1].PlayState = "Stopped"
			end

			if not activeAttack then
				local newColor = sm.color.lerp( PreviewBarColor1, PreviewBarColor2, ( math.sin( math.rad( self.cl.oscillationTimer * 180 / OscillationFrequency ) ) + 1 ) * 0.5 )
				RaidPanelGui.index.RaidBarPreview.Colour = newColor:getGuiColorStr()
				RaidPanelGui.index.RaidBarPreviewSuper.Colour = newColor:getGuiColorStr()
				self.cl.oscillationTimer = self.cl.oscillationTimer + deltaTime
			else
				RaidPanelGui.index.RaidBarPreview.Colour = "1 1 1 1"
			end

			local plantValue = 0
			if self.cl.heldPlant and not activeAttack then
				plantValue = GetPlantValue( self.cl.heldPlant )
			end
			local fullSteps = GetRaidGuiMilestone( raid.raidSync.value )
			local fraction = GetRaidGuiFraction( raid.raidSync.value )
			local previewSteps = GetRaidGuiMilestone( raid.raidSync.value + plantValue )
			local previewFraction = GetRaidGuiFraction( raid.raidSync.value + plantValue )
			local isLoss = false
			if raid.cl.fromValue then
				isLoss = raid.raidSync.value < raid.cl.fromValue
			end
			if not isLoss then
				RaidPanelGui.index.RaidBarPreview.width = math.min( math.floor( previewSteps * BarSectionWidth + previewFraction * BarSectionWidth ), BarSectionWidth * 3 )
				if GetRaidIsSuper( raid.raidSync.value + plantValue ) then
					local superFraction = GetRaidSuperFraction( raid.raidSync.value + plantValue )
					RaidPanelGui.index.RaidBarPreviewSuper.width = math.floor( superFraction * SuperBarWidth )
				end
			else
				for i = 1, #RaidPanelGui.raidBars do
					RaidPanelGui.raidBars[i].width = math.min( math.floor( fullSteps * BarSectionWidth + fraction * BarSectionWidth ), BarSectionWidth * i )
					RaidPanelGui.raidBars[i].Visible = fullSteps + 1 >= i
				end
			end

			if raid.cl.barDelayTimer > DelayBeforeBarMovement then
				if raid.cl.fromValue or not ( RaidPanelGui.index.RaidBar.Alpha == 1 or RaidPanelGui.index.RaidBar.Alpha == 0.0 ) then
					RaidPanelGui.index.RaidBarHighlightEffect.Visible = true
					local fromValue = raid.cl.fromValue or raid.raidSync.value
					local lerpValue = lerp( fromValue, raid.raidSync.value, raid.cl.barMoveTimer / BarMoveDuration )
					local lerpSteps = GetRaidGuiMilestone( lerpValue )
					local lerpFraction = GetRaidGuiFraction( lerpValue )
					if not GetRaidIsSuper( lerpValue ) then
						if RaidPanelGui.index.RaidBar.Alpha < 1 then
							local newAlpha = lerp( 0.0, 1.0, raid.cl.alphaSwapTimer / SuperBarAlphaSwapTime )
							RaidPanelGui.index.RaidBar.Alpha = newAlpha
							for _,data in ipairs( RaidPanelGui.index.RaidBar.Childs ) do
								data.Alpha = newAlpha
							end
							raid.cl.alphaSwapTimer = raid.cl.alphaSwapTimer + deltaTime
						end
						if not isLoss and not activeAttack then
							for i = 1, #RaidPanelGui.raidBars do
								RaidPanelGui.raidBars[i].width = math.min( math.floor( lerpSteps * BarSectionWidth + lerpFraction * BarSectionWidth ), BarSectionWidth * i )
								RaidPanelGui.raidBars[i].Visible = lerpSteps + 1 >= i
							end
							for i = 1, math.min( lerpSteps, #RaidPanelGui.milestones ) do
								local playEffect = RaidPanelGui.milestones[i].Visible == false
								if playEffect then
									local widget = raid.cl.raidStatusJsonGui:getWidget( MilestoneEffectBoxNames[i] )
									if widget then
										widget:startEffect( "ping" )
									end
								end
								RaidPanelGui.milestones[i].Visible = true
							end
							local enableHighlight = false
							local fromStep = GetRaidGuiMilestone( fromValue )
							local toSteps = GetRaidGuiMilestone( raid.raidSync.value )
							if fromStep < toSteps then
								enableHighlight = true
							end
							if not enableHighlight then
								local fromFraction = GetRaidGuiFraction( fromValue )
								local toFraction = GetRaidGuiFraction( raid.raidSync.value )
								if toFraction - fromFraction >= 0.12 then
									enableHighlight = true
								end
							end
							RaidPanelGui.index.RaidBarHighlight.Visible = enableHighlight
							if enableHighlight then
								RaidPanelGui.index.RaidBarHighlightEffect.Effects[1].PlayState = "Auto play once"
							end
							if lerpSteps + 1 <= #RaidPanelGui.raidBars then
								RaidPanelGui.index.RaidBarHighlight.x = RaidPanelGui.raidBars[lerpSteps + 1].width + 1
								RaidPanelGui.index.RaidBarHighlightEffect.x = RaidPanelGui.raidBars[lerpSteps + 1].width
							end
						else
							RaidPanelGui.index.RaidBarPreview.width = math.floor( lerpSteps * BarSectionWidth + lerpFraction * BarSectionWidth )
							for i = lerpSteps + 1, #RaidPanelGui.milestones do
								RaidPanelGui.milestones[i].Visible = false
							end
							for i = 1, math.min( fullSteps, #RaidPanelGui.milestones ) do
								RaidPanelGui.milestones[i].Visible = true
							end
						end
					else -- Super bar
						RaidPanelGui.index.RaidBarSuper.Visible = true
						RaidPanelGui.index.RaidBarHighlightEffect.Visible = false
						if RaidPanelGui.index.RaidBar.Alpha == 1 then
							for i = 1, #RaidPanelGui.milestones do
								RaidPanelGui.milestones[i].Visible = false
							end
						end
						if RaidPanelGui.index.RaidBar.Alpha > 0 then
							local newAlpha = lerp( 1.0, 0.0, raid.cl.alphaSwapTimer / SuperBarAlphaSwapTime )
							RaidPanelGui.index.RaidBar.Alpha = newAlpha
							for _,data in ipairs( RaidPanelGui.index.RaidBar.Childs ) do
								data.Alpha = newAlpha
							end
							raid.cl.alphaSwapTimer = raid.cl.alphaSwapTimer + deltaTime
						end

						local superLerpFraction = GetRaidSuperFraction( lerpValue )
						if not isLoss and not activeAttack then
							RaidPanelGui.index.RaidBarFillSuper.width = math.floor( SuperBarWidth * superLerpFraction )
							RaidPanelGui.index.RaidBarHighlightSuper.x = RaidPanelGui.index.RaidBarFillSuper.width + 1
							RaidPanelGui.index.RaidBarHighlightSuperEffect.x = RaidPanelGui.index.RaidBarFillSuper.width
							local enableHighlight = false
							local fromFraction = GetRaidSuperFraction( fromValue )
							local toFraction = GetRaidSuperFraction( raid.raidSync.value )
							if toFraction - fromFraction > 0.04 then
								enableHighlight = true
							end
							RaidPanelGui.index.RaidBarHighlightSuper.Visible = enableHighlight

							if enableHighlight then
								RaidPanelGui.index.RaidBarHighlightSuperEffect.Effects[1].PlayState = "Auto play once"
							end
						else
							local superAbsolueFraction = GetRaidSuperFraction( raid.raidSync.value )
							RaidPanelGui.index.RaidBarFillSuper.width = math.floor( SuperBarWidth * superAbsolueFraction )
							RaidPanelGui.index.RaidBarPreviewSuper.width = math.floor( SuperBarWidth * superLerpFraction )
						end
					end
					if lerpValue == raid.raidSync.value then
						raid.cl.fromValue = nil
					end
				else
					raid.cl.fromValue = nil
					if not raid.cl.previousShowGui then
						if GetRaidIsSuper( raid.raidSync.value ) then
							RaidPanelGui.index.RaidBar.Alpha = 0
							for _,data in ipairs( RaidPanelGui.index.RaidBar.Childs ) do
								data.Alpha = 0
							end
							local superLerpFraction = GetRaidSuperFraction( raid.raidSync.value )
							local superAbsolueFraction = GetRaidSuperFraction( raid.raidSync.value )
							RaidPanelGui.index.RaidBarFillSuper.width = math.floor( SuperBarWidth * superAbsolueFraction )
							RaidPanelGui.index.RaidBarPreviewSuper.width = math.floor( SuperBarWidth * superLerpFraction )
						else
							RaidPanelGui.index.RaidBar.Alpha = 1
							for _,data in ipairs( RaidPanelGui.index.RaidBar.Childs ) do
								data.Alpha = 1
							end
							for i = 1, #RaidPanelGui.raidBars do
								RaidPanelGui.raidBars[i].width = math.min( math.floor( fullSteps * BarSectionWidth + fraction * BarSectionWidth ), BarSectionWidth * i )
								RaidPanelGui.raidBars[i].Visible = fullSteps + 1 >= i
							end
							for i = 1, math.min( fullSteps, #RaidPanelGui.milestones ) do
								RaidPanelGui.milestones[i].Visible = true
							end
						end
					end
				end
				raid.cl.barMoveTimer = raid.cl.barMoveTimer + deltaTime
			end
			raid.cl.barDelayTimer = raid.cl.barDelayTimer + deltaTime
			raid.cl.raidStatusJsonGui:render( RaidPanelGui.root )
		elseif not showInfo then
			-- Destroy gui
			if raid.cl.raidStatusJsonGui then
				raid.cl.raidStatusJsonGui:close()
				raid.cl.raidStatusJsonGui = nil
				raid.cl.startEffectPlayed = false
				raid.cl.guiCreationTick = nil
				RaidPanelGui.index.RaidActiveStartEffect.Effects[1].PlayState = "Stopped"
				RaidPanelGui.index.RaidActiveStartEffect.Effects[2].PlayState = "Stopped"
				RaidPanelGui.index.RaidActiveStartEffect.Effects[3].PlayState = "Stopped"
				RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[1].PlayState = "Stopped"
				RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[2].PlayState = "Stopped"
				RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[3].PlayState = "Stopped"
			end
		end

		-- active raid effect activations
		if activeAttack and raid.cl.raidStatusJsonGui and ( currentTick - raid.cl.guiCreationTick ) < GuiFadeInDuration * 40 then -- Effect when entering active raid area
			if GetRaidIsSuper( raid.raidSync.value ) then
				if not raid.cl.startEffectPlayed then
					raid.cl.startEffectPlayed = true
					RaidPanelGui.index.RaidActiveStartEffect.Effects[3].PlayState = "Stopped"
					RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[3].PlayState = "Auto play once"
				end
			else
				if not raid.cl.startEffectPlayed then
					raid.cl.startEffectPlayed = true
					RaidPanelGui.index.RaidActiveStartEffect.Effects[3].PlayState = "Auto play once"
					RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[3].PlayState = "Stopped"
				end
			end
		end

		if activeAttack and raid.cl.raidStatusJsonGui and ( RaidPanelGui.index.RaidActiveStartEffect.Effects[2].PlayState == "Stopped" or RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[2].PlayState == "Stopped" ) then
			if GetRaidIsSuper( raid.raidSync.value ) and RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[2].PlayState == "Stopped" then
				RaidPanelGui.index.RaidActiveStartEffect.Effects[1].PlayState = "Stopped"
				RaidPanelGui.index.RaidActiveStartEffect.Effects[2].PlayState = "Stopped"
				RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[1].PlayState = "Auto play once"
				RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[2].PlayState = "Auto play once"
			elseif not GetRaidIsSuper( raid.raidSync.value ) and RaidPanelGui.index.RaidActiveStartEffect.Effects[2].PlayState == "Stopped" then
				RaidPanelGui.index.RaidActiveStartEffect.Effects[1].PlayState = "Auto play once"
				RaidPanelGui.index.RaidActiveStartEffect.Effects[2].PlayState = "Auto play once"
				RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[1].PlayState = "Stopped"
				RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[2].PlayState = "Stopped"
			end
		end

		if showMarker then
			if showFarMarker then
				if raid.cl.markerEffectFar == nil then
					raid.cl.markerEffectFar = sm.effect.createEffect( "RaidMarkerFar" )
					raid.cl.markerEffectFar:setPosition( raid.cl.guiWorldPosition + RaidMarkerOffset )
				end
				if not raid.cl.markerEffectFar:isPlaying() then
					raid.cl.markerEffectFar:start()
				end
				if raid.cl.previousPosition ~= raid.cl.guiWorldPosition then
					raid.cl.markerEffectFar:setPosition( raid.cl.guiWorldPosition + RaidMarkerOffset )
				end
			elseif raid.cl.markerEffectFar and raid.cl.markerEffectFar:isPlaying() then
				raid.cl.markerEffectFar:stop()
			end

			if showNearMarker then
				if raid.cl.markerEffectNear == nil then
					raid.cl.markerEffectNear = sm.effect.createEffect( "RaidMarkerNear" )
					raid.cl.markerEffectNear:setPosition( raid.cl.guiWorldPosition + RaidMarkerOffset )
				end
				if not raid.cl.markerEffectNear:isPlaying() then
					raid.cl.markerEffectNear:start()
				end
				if raid.cl.previousPosition ~= raid.cl.guiWorldPosition then
					raid.cl.markerEffectNear:setPosition( raid.cl.guiWorldPosition + RaidMarkerOffset )
				end
				local stringValue = GetCountdownText( raid, currentTick )
				raid.cl.markerEffectNear:setParameter( "TextContent", stringValue )
			elseif raid.cl.markerEffectNear and raid.cl.markerEffectNear:isPlaying() then
				raid.cl.markerEffectNear:stop()
			end
		else
			-- Destroy gui
			if raid.cl.markerEffectNear then
				raid.cl.markerEffectNear:destroy()
				raid.cl.markerEffectNear = nil
			end
			if raid.cl.markerEffectFar then
				raid.cl.markerEffectFar:destroy()
				raid.cl.markerEffectFar = nil
			end
		end
		-- The raid compass icon shows for the whole countdown and after the drops start only while the player is far
		if g_compassHud then
			local showRaidCompass = showMarker and ( countdownStarted or not insideRaidArea )
			if showRaidCompass then
				if raid.cl.compassPlaced == nil then
					raid.cl.compassPlaced = true
					g_compassHud:compassAddIcon( raid.raidSync.key, "icon_compass_bot.png" )
					g_compassHud:compassSetIconWorldPosition( raid.raidSync.key, raid.cl.guiWorldPosition )
				elseif raid.cl.previousPosition ~= raid.cl.guiWorldPosition then
					g_compassHud:compassSetIconWorldPosition( raid.raidSync.key, raid.cl.guiWorldPosition )
				end
				g_compassHud:setVisible( raid.raidSync.key, true )
			elseif raid.cl.compassPlaced then
				if showMarker then
					g_compassHud:setVisible( raid.raidSync.key, false )
				else
					g_compassHud:compassRemoveIcon( raid.raidSync.key )
					raid.cl.compassPlaced = nil
				end
			end
		end
		raid.cl.isClosest = nil
		raid.cl.previousShowGui = showInfo
	end
	if closestRaidId and raids[closestRaidId] then
		raids[closestRaidId].cl.isClosest = true
	end

	if anyRaidControllingGui then
		if self.cl.localPlayerPlantingGui == nil then
			self.cl.localPlayerPlantingGui = sm.jsonGui.createGui( { isHud = true, needsCursor = false, isInteractive = false } )
		end
	end

	if self.cl.heldPlant and GetPlantValue( self.cl.heldPlant ) > 0 and not anyRaidControllingGui then
		local plantValue = GetPlantValue( self.cl.heldPlant )
		if plantValue == 0 then
			return
		end
		if self.cl.localPlayerPlantingGui == nil then
			self.cl.localPlayerPlantingGui = sm.jsonGui.createGui( { isHud = true, needsCursor = false, isInteractive = false } )
		end
		RaidPanelGui.raidBars[1].width = 0
		RaidPanelGui.raidBars[2].width = 0
		RaidPanelGui.raidBars[3].width = 0
		for i = 1, #RaidPanelGui.milestones do
			RaidPanelGui.milestones[i].Visible = false
		end

		local level = GetRaidGuiMilestone( plantValue )
		local fraction = GetRaidGuiFraction( plantValue )
		local newColor = sm.color.lerp( PreviewBarColor1, PreviewBarColor2, ( math.sin( math.rad( self.cl.oscillationTimer * 180 / OscillationFrequency ) ) + 1 ) * 0.5 )
		RaidPanelGui.index.RaidBarPreview.Colour = newColor:getGuiColorStr()
		self.cl.oscillationTimer = self.cl.oscillationTimer + deltaTime

		RaidPanelGui.index.RaidBarPreview.width = math.floor( ( BarSectionWidth * level ) + ( fraction * BarSectionWidth ) )
		self:cl_handleGuiFade( true, deltaTime )

	elseif self.cl.localPlayerPlantingGui and not anyRaidControllingGui then
		self:cl_handleGuiFade( anyRaidControllingGui, deltaTime )
	elseif not anyRaidControllingGui and RaidPanelGui.raidBars[1].width > 0 then
		-- reset values
		self.cl.oscillationTimer = 0
		RaidPanelGui.raidBars[1].width = 0
		RaidPanelGui.raidBars[2].width = 0
		RaidPanelGui.raidBars[3].width = 0
		RaidPanelGui.index.RaidBarPreview.width = 0
		RaidPanelGui.index.RaidBarPreview.Colour = "1 1 1 1"
		RaidPanelGui.index.RaidBarPreviewSuper.width = 0
		RaidPanelGui.index.RaidBarFillSuper.width = 0
		RaidPanelGui.index.RaidActiveStartEffect.Effects[1].PlayState = "Stopped"
		RaidPanelGui.index.RaidActiveStartEffect.Effects[2].PlayState = "Stopped"
		RaidPanelGui.index.RaidActiveStartEffect.Effects[3].PlayState = "Stopped"
		RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[1].PlayState = "Stopped"
		RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[2].PlayState = "Stopped"
		RaidPanelGui.index.SuperRaidActiveStartEffect.Effects[3].PlayState = "Stopped"
		for i = 1, #RaidPanelGui.milestones do
			RaidPanelGui.milestones[i].Visible = false
		end
		RaidPanelGui.index.RaidBarHighlightSuper.Visible = false
		RaidPanelGui.index.RaidBarHighlightSuperEffect.Effects[1].PlayState = "Stopped"
		RaidPanelGui.index.RaidBarHighlightEffect.Effects[1].PlayState = "Stopped"
		RaidPanelGui.index.RaidBar.Alpha = 1
		for _,data in ipairs( RaidPanelGui.index.RaidBar.Childs ) do
			data.Alpha = 1
		end
		RaidPanelGui.index.RaidBarPreview.width = 0
		self:cl_handleGuiFade( anyRaidControllingGui, deltaTime )
	end
end