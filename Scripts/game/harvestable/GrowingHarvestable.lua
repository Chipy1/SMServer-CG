-- GrowingHarvestable.lua --
dofile "$CONTENT_DATA/Scripts/game/survival_harvestable.lua"
dofile( "$CONTENT_DATA/Scripts/game/managers/QuestManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/RaidManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/survival_raids.lua" )

GrowingHarvestable = class( nil )
GrowingHarvestable.poseWeightCount = 2

local MaxSoilFrame = 9
local WaterRetentionTickTime = DAYCYCLE_TIME_TICKS * 1.5
local WetStepTime = WaterRetentionTickTime / MaxSoilFrame

local IgnoreProjectiles = {
	projectile_colorblob
}

-- Server
function GrowingHarvestable.server_onCreate( self )
	self.sv = {}
	self.sv.saved = self.storage:load() or {}
	self.sv.saved.waterTick = self.sv.saved.waterTick or nil
	self.sv.saved.fertilizeTick = self.sv.saved.fertilizeTick or nil
	if self.sv.saved.hasSurvivedRaid == nil then
		self.sv.saved.hasSurvivedRaid = true -- let old plants act as they have survived a raid
	end
	self.sv.saved.growStartTick = self.sv.saved.growStartTick or nil

	if self.params then
		if self.params.waterTick then
			self.sv.saved.waterTick = self.params.waterTick
			self.sv.saved.growStartTick = sm.game.getCurrentTick()
		end
		if self.params.fertilizer then
			self.sv.saved.fertilizeTick = sm.game.getCurrentTick()
		end
		if self.params.raidKey then
			self.sv.saved.raidKey = self.params.raidKey
			self.sv.saved.hasSurvivedRaid = false
		end
		self:sv_saveAndSync()
	else
		self.network:setClientData( { waterTick = self.sv.saved.waterTick, fertilizeTick = self.sv.saved.fertilizeTick, growStartTick = self.sv.saved.growStartTick } )
	end
end

function GrowingHarvestable.sv_saveAndSync( self )
	self.storage:save( self.sv.saved )
	self.network:setClientData( { waterTick = self.sv.saved.waterTick, fertilizeTick = self.sv.saved.fertilizeTick, growStartTick = self.sv.saved.growStartTick } )
end

-- A plant adopted by a raid waits for the raid to end before it can mature
function GrowingHarvestable.sv_updateRaidGate( self )
	local saved = self.sv.saved
	if saved.hasSurvivedRaid or g_raidManager == nil then
		return
	end
	if saved.raidKey == nil then
		-- Saved before plants carried their raid key: find its raid by position, and release it if none holds it
		saved.raidKey = RaidManager.Sv_GetCropRaidKey( self.harvestable )
		saved.hasSurvivedRaid = saved.raidKey == nil
		self.storage:save( saved )
	elseif RaidManager.Sv_IsRaidOver( self.harvestable:getWorld().id, saved.raidKey ) then
		saved.hasSurvivedRaid = true
		self.storage:save( saved )
	end
end

function GrowingHarvestable.sv_destroy( self )
	if not self.sv.harvested and sm.exists( self.harvestable ) then
		self:sv_updateRaidGate() -- finds the raid of a plant saved before keys existed
		sm.effect.playEffect( "Plants - Destroyed", self.harvestable:getPosition() )
		local createdHarvestable = sm.harvestable.createHarvestable( hvs_soil, self.harvestable:getPosition(), self.harvestable:getRotation() )
		createdHarvestable:setParams( { waterTick = self.sv.saved.waterTick, fertilizer = self.sv.saved.fertilizeTick ~= nil } )
		if self.sv.saved.raidKey then
			RaidManager.Sv_CropDestroyed( self.harvestable, self.sv.saved.raidKey )
		end
		sm.harvestable.destroy( self.harvestable )
		self.sv.harvested = true
	end
end

function GrowingHarvestable.sv_done( self )
	if not self.sv.harvested and sm.exists( self.harvestable ) then
		sm.effect.playEffect( "Plants - Done", self.harvestable:getPosition() )
		local uuid = sm.uuid.new( self.data.harvestable )
		sm.harvestable.createHarvestable( uuid, self.harvestable:getPosition(), self.harvestable:getRotation() )
		sm.harvestable.destroy( self.harvestable )
		self.sv.harvested = true
	end
end

function GrowingHarvestable.server_onReceiveUpdate( self )
	self:sv_updateRaidGate()
	if not self.sv.harvested and sm.exists( self.harvestable ) then
		local currentTick = sm.game.getCurrentTick()
		local fertilizeTicks = ( self.sv.saved.fertilizeTick and self.sv.saved.growStartTick ) and ( currentTick - math.max( self.sv.saved.fertilizeTick, self.sv.saved.growStartTick ) ) or 0
		local growTicks = self.sv.saved.growStartTick and ( currentTick - self.sv.saved.growStartTick + fertilizeTicks * 14 ) or 0
		local growTickTime = DAYCYCLE_TIME_TICKS * ( self.data and self.data.daysToGrow or 0.875 )
		if growTicks >= growTickTime and self.sv.saved.hasSurvivedRaid then
			self:sv_done()
			return
		end
	end
	if WeatherManager.Sv_IsRaining() then
		self.sv.saved.waterTick = self.sv.saved.waterTick or ( sm.game.getCurrentTick() - WaterRetentionTickTime )
		self.sv.saved.waterTick = math.min( self.sv.saved.waterTick + DAYCYCLE_TIME_TICKS * 0.1, sm.game.getCurrentTick() )
		self.sv.saved.growStartTick = self.sv.saved.growStartTick or sm.game.getCurrentTick()
		self:sv_saveAndSync()
	end
end

function GrowingHarvestable.server_onMelee( self, hitPos, attacker, damage, power, hitDirection )
	self:sv_destroy()
end











function GrowingHarvestable.server_onProjectile( self, hitPos, hitTime, hitVelocity, _, attacker, damage, userData, hitNormal, projectileUuid )
	if projectileUuid == projectile_fertilizer then
		self.sv.saved.fertilizeTick = sm.game.getCurrentTick()
		self:sv_saveAndSync()
	elseif type( attacker ) == "Unit" then
		if not isAnyOf( projectileUuid, IgnoreProjectiles ) then
			self:sv_destroy()
		end
	end
end

function GrowingHarvestable.sv_e_waterSoil( self )
	self.sv.saved.waterTick = sm.game.getCurrentTick()
	self.sv.saved.growStartTick = self.sv.saved.growStartTick or sm.game.getCurrentTick()
	self:sv_saveAndSync()
end

function GrowingHarvestable.sv_e_fertilize( self, params )
	if not self.sv.saved.fertilizeTick then
		if sm.container.beginTransaction() then
			sm.container.spendFromSlot( params.playerInventory, params.slot, ITEMS.obj_consumable_fertilizer, 1 )
			if sm.container.endTransaction() then
				self.sv.saved.fertilizeTick = sm.game.getCurrentTick()
				self:sv_saveAndSync()
			end
		end
	end
end

-- Client
function GrowingHarvestable.client_onCreate( self )
	self.cl = {}
	self.cl.waterTick = nil
	self.cl.growStartTick = nil
	self.cl.fertilizeTick = nil
	self.cl.createTick = sm.game.getCurrentTick()
	self.harvestable.clientPublicData = {}
	self.harvestable.clientPublicData.fertilizer = false
end

function GrowingHarvestable.client_onUpdate( self, dt )
	local serverTick = sm.game.getServerTick()

	-- Visual uv scroll wetness
	local soilFrameIndex = 0
	if self.cl.waterTick then
		local ticksSinceWatered = serverTick - self.cl.waterTick
		soilFrameIndex = clamp( MaxSoilFrame - math.floor( ticksSinceWatered / WetStepTime ), 1, MaxSoilFrame )
	end
	self.harvestable:setUvFrameIndex( soilFrameIndex )

	-- Visual growth progress
	local fertilizeTicks = ( self.cl.fertilizeTick and self.cl.growStartTick ) and ( serverTick - math.max( self.cl.fertilizeTick, self.cl.growStartTick ) ) or 0
	local growTicks = self.cl.growStartTick and ( serverTick - self.cl.growStartTick + fertilizeTicks * 20 ) or 0
	local growTickTime = DAYCYCLE_TIME_TICKS * ( self.data and self.data.daysToGrow or 0.875 )
	local growFraction = growTicks / growTickTime
	--Blend from 1.0 to 0.0 over the course of 0 to 0.5 of the growth progress
	local firstWeight = 1.0 - clamp( growFraction * 2, 0, 1 )
	--Blend from 0.0 to 1.0 over the course of 0.5 to 1.0 of the growth progress
	local secondWeight = clamp( growFraction - 0.5, 0, 0.5 ) * 2
	self.harvestable:setPoseWeight( 0, firstWeight )
	self.harvestable:setPoseWeight( 1, secondWeight )
end

function GrowingHarvestable.client_onClientDataUpdate( self, clientData )
	self.cl.waterTick = clientData.waterTick
	self.cl.growStartTick = clientData.growStartTick
	if not self.cl.fertilizeTick and clientData.fertilizeTick then
		if sm.game.getCurrentTick() > self.cl.createTick then
			sm.effect.playEffect( "Plants - Fertilizer_impact", self.harvestable:getPosition() )
		end
		sm.effect.playHostedEffect( "Plants - Fertilizer_loop", self.harvestable )
		self.cl.fertilizeTick = clientData.fertilizeTick
	end
	self.harvestable.clientPublicData.fertilizer = self.cl.fertilizeTick ~= nil
end
