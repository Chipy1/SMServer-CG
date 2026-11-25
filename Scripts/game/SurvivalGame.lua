if not sm.pcall then
	local ENDOF = {}

	function sm.pcall(field, ...)
		local result = {pcall(...), ENDOF}
		if not result[1] then sm.log.error(field, result[2]) end

		local i = 1
		while result[i] ~= ENDOF do
			i = i + 1
		end

		return unpack(result, 1, i - 1)
	end
end

print = sm.log.info

dofile( "$CONTENT_DATA/Scripts/loader.lua")
dofile( "$CONTENT_DATA/Scripts/game/managers/BeaconManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/DialogManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/EffectManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/ElevatorManager.lua"  )
dofile( "$CONTENT_DATA/Scripts/game/managers/MinidungeonElevatorManager.lua"  )
dofile( "$CONTENT_DATA/Scripts/game/managers/QuestManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/RespawnManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/UnitManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/WorldManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/survival_constants.lua" )
dofile( "$CONTENT_DATA/Scripts/game/survival_harvestable.lua" )
dofile( "$CONTENT_DATA/Scripts/game/survival_shapes.lua" )
dofile( "$CONTENT_DATA/Scripts/game/survival_units.lua" )
dofile( "$CONTENT_DATA/Scripts/game/survival_projectiles.lua" )
dofile( "$CONTENT_DATA/Scripts/game/survival_meleeattacks.lua" )
dofile( "$CONTENT_DATA/Scripts/game/util/recipes.lua" )
dofile( "$CONTENT_DATA/Scripts/game/util/Timer.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/QuestEntityManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/RaidManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/TileStorageManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/KinematicManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/WarehouseManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/UndergroundElevatorManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/ScannerbotManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/RecipeManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/TutorialManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/WeatherManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/PatrolManager.lua" )
dofile( "$CUSTOMIZATION_DATA/Scripts/game/quest_reward_util.lua" )
dofile( "$CONTENT_DATA/Scripts/smserver/core.lua" )

local table_remove = table.remove

-- Read by EffectManager to decide whether a named cinematic needs server-side playback:
-- server_onCreate sets it to true and client_onCreate clears it, so a listen-server host and a
-- connected client report false while a dedicated server keeps true. It is deliberately global:
-- manager scriptable objects share the game Lua state.
g_isDedicatedServer = nil

--[[
local HOST_EXCLUDE_FLAG_STORAGE_KEY = "__EXCLUDE_HOST_PLAYER_FLAG"
g_excludeHostPlayer = sm.storage.load( HOST_EXCLUDE_FLAG_STORAGE_KEY ) == true

-- Custom game: g_excludeHostPlayer hides the host player from stock code.
--
-- Measured on 1.0.7.896 dedicated (-dedicated_server -last_save): sm.isHost is
-- true, getHostPlayer() returns the real host player (id=1, name=Chipy) and
-- getAllPlayers() returns 1 entry. getHostPlayer() is therefore NOT nil on a
-- dedicated server, but the host entry *is* present in the player list even
-- though no host client is connected.
--
-- Consequence: excluding that entry unconditionally empties the list on a
-- dedicated server. RaidManager's per-tick HasNearbyPlayer() then never sees a
-- player, so a raid never loads cells, never generates spawn points and never
-- spawns its waves. The filter therefore refuses to remove the last entry.
local old_sm_player_getAllPlayers = sm.player.getAllPlayers
local hostExcludeWarningLogged = false
function sm.player.getAllPlayers( ... )
	local list = old_sm_player_getAllPlayers( ... )
	if not g_excludeHostPlayer or type( list ) ~= "table" then
		return list
	end
	local ok, host = pcall( sm.player.getHostPlayer )
	if not ok or host == nil or host.id == nil then
		if not hostExcludeWarningLogged then
			hostExcludeWarningLogged = true
			sm.log.warning( "SMSERVER: g_excludeHostPlayer is enabled but there is no host player; host exclusion is inactive" )
		end
		return list
	end
	-- Never return an empty list: an empty player list disables raids, unit
	-- targeting and every stock system that probes for nearby players.
	if #list <= 1 then
		return list
	end
	for index = #list, 1, -1 do
		local player = list[ index ]
		if player ~= nil and player.id == host.id then
			table.remove( list, index )
		end
	end
	return list
end


]]

local HOST_EXCLUDE_FLAG_STORAGE_KEY = "__EXCLUDE_HOST_PLAYER_FLAG"
g_excludeHostPlayer = (sm.storage.load( HOST_EXCLUDE_FLAG_STORAGE_KEY ) == true)

local sm_player_getAllPlayers = sm.player.getAllPlayers
local sm_player_getHostPlayer = sm.player.getHostPlayer

get_host_player_chestno = sm_player_getHostPlayer

--function sm.player.getAllPlayers( ... )
--	local list = sm_player_getAllPlayers(...)
--	if g_excludeHostPlayer or g_isDedicatedServer then
--		local host_player = sm_player_getHostPlayer()
--		for i, player in ipairs(list) do
--			if player.id == host_player.id then
--				table_remove(list, i)
--			end
--		end
--	end
--	return list
--end
--
--function sm.player.getHostPlayer( ... )
--	if not g_excludeHostPlayer and not g_isDedicatedServer then
--		return sm_player_getHostPlayer(...)
--	end
--end




g_PlayerInventoryMaxSlots = 50


---@class SurvivalGame : GameClass
---@field sv table
---@field cl table
---@field warehouses table
SurvivalGame = class( nil )
SurvivalGame.enableLimitedInventory = true
SurvivalGame.enableRestrictions = true
SurvivalGame.enableFuelConsumption = true
SurvivalGame.enableAmmoConsumption = true
SurvivalGame.enableUpgrade = true
SurvivalGame.defaultInventorySize = g_PlayerInventoryMaxSlots

local SyncInterval = 400 -- 400 ticks | 10 seconds
local SmserverSpawnerUuid = sm.uuid.new( "ef0da7c7-84f2-41c7-9e58-347b98932b7f" )
local BlockedShapeUuids = {
	["3d127db0-da28-4483-86fd-3eeed20fb85d"] = true,
}

local function isBlockedShapeUuid( uuid )
	return BlockedShapeUuids[tostring( uuid )] == true or smserver_isBlockedItem( uuid )
end


sm_game_banPlayer_chestno = sm.game.banPlayer
function SurvivalGame.__banPlayer(self, player, caller)
	if caller then
		self:__banPlayer(caller)
		return
	end
	self.sv.saved.banned_ids[player.id] = true
	sm.game.kickPlayer(player)
end

function sm.game.banPlayer(player)
	sm.event.sendToGame("__banPlayer", player, sm.event.types.instant)
end

function sm.game.unbanPlayer(player)
	sm.event.sendToGame("__banPlayer", player, sm.event.types.instant)
end

function SurvivalGame.__unbanPlayer(self, player, caller)
	if caller then
		self:__banPlayer(caller)
		return
	end
	self.sv.saved.banned_ids[player.id] = nil
end

function SurvivalGame.server_onCreate( self )
	g_isDedicatedServer = true
	self.sv = {
		saved = self.storage:load()
	}
	
	if self.sv.saved == nil then
		self.sv.saved = {
			data = self.data,
			banned_ids = {},
			player_warns = {}
		}
		
		printf( "Seed: %.0f", self.data.seed )
		self.sv.saved.overworld = sm.world.createWorld( "$CONTENT_DATA/Scripts/game/worlds/Overworld.lua", "Overworld", { dev = self.data.dev }, self.data.seed )
	else
		if not self.sv.saved.banned_ids then
			self.sv.saved.banned_ids = {}
		end
		if not self.sv.saved.player_warns then
			self.sv.saved.player_warns = {}
		end
		if self.sv.saved.overworld and not sm.exists( self.sv.saved.overworld ) then
			-- Load overworld to create TileStorageKeys
			sm.world.loadWorld( self.sv.saved.overworld )
		end
	end

	g_player_warns = self.sv.saved.player_warns
	
	self.sv.saved.lootTier = self.sv.saved.lootTier or 1
	g_lootTier = self.sv.saved.lootTier
	self.sv.saved.smserver = self.sv.saved.smserver or {}
	self.sv.saved.smserver.admins = self.sv.saved.smserver.admins or {}
	servicetool.admins = self.sv.saved.smserver.admins
	self.storage:save( self.sv.saved )

	self.data = nil






	
	self:loadCraftingRecipes()
	g_enableCollisionTumble = true


	g_kinematicManager = KinematicManager()
	g_kinematicManager:sv_onCreate()

	WorldManager.Sv_OnCreate()

	g_respawnManager = RespawnManager()
	g_respawnManager:sv_onCreate( self.sv.saved.overworld )

	g_beaconManager = BeaconManager()
	g_beaconManager:sv_onCreate()

	g_unitManager = UnitManager()
	g_unitManager:sv_onCreate( self.sv.saved.overworld )

	self.sv.questManager = sm.storage.load( STORAGE_CHANNEL_QUESTMANAGER )
	if not self.sv.questManager then
		self.sv.questManager = sm.scriptableObject.createScriptableObject( sm.uuid.new( "83b0cc7e-b164-47b8-a83c-0d33ba5f72ec" ) )
		sm.storage.save( STORAGE_CHANNEL_QUESTMANAGER, self.sv.questManager )
	end

	--self.sv.scannerbotManager = sm.scriptableObject.createScriptableObject( sm.uuid.new( "2760488f-98a9-4cad-9d24-0b9fca45f91f" ), nil, self.sv.saved.overworld )

	self.sv.undergroundWorlds = sm.storage.load( STORAGE_CHANNEL_UNDERGROUND_WORLDS )
	if not self.sv.undergroundWorlds then
		self.sv.undergroundWorlds = {}
		sm.storage.save( STORAGE_CHANNEL_UNDERGROUND_WORLDS, self.sv.undergroundWorlds )
	end



	self.sv.time = sm.storage.load( STORAGE_CHANNEL_TIME )
	if self.sv.time then
		print( "Loaded timeData:", self.sv.time)
	else
		self.sv.time = {}
		self.sv.time.timeOfDay = GAME_START_TIME -- 06:00
		self.sv.time.timeProgress = true
		sm.storage.saveAndSync( STORAGE_CHANNEL_TIME, self.sv.time )
	end
	self.sv.gotoLocations = { "marker", "start", "mechanicstation", "hideout", "mainelevator", "excavation", "questfarmer", "questwarehouse", "garage", "scannerbot", "void",
		"underground1", "underground2", "underground3", "underground4", "underground5", "underground6", "underground7", "underground8" }
	self.network:setClientData( { dev = g_survivalDev, gotoLocations = self.sv.gotoLocations }, 1 )
	self:sv_updateClientData()

	self.sv.syncTimer = Timer()
	self.sv.syncTimer:start( 0 )

	-- Deferred: scriptable object references are only guaranteed to be resolved after the load
	-- sequence, and the check must not run before that.
	self.sv.bosstrainRepairTick = sm.game.getCurrentTick() + 20
	-- The raid manager is a base-game singleton scriptable object. Log once whether it exists,
	-- so a dedicated log shows immediately whether raids can run at all in this custom game.
	self.sv.raidManagerCheckTick = sm.game.getCurrentTick() + 20
	-- One-shot environment probe: records whether getHostPlayer() actually returns a player here.
	-- The API stub declares a non-optional return, so only a real run can tell whether it is nil
	-- on a dedicated server. Change this into a guaranteed-safe guard once the log settles it.
	self.sv.hostProbeTick = sm.game.getCurrentTick() + 20
end

-- A save can end up with the bosstrain quest in a state where no quest object is alive: either it is
-- flagged as completed, or it is listed as active but the object is gone. In both cases
-- BosstrainQuest.server_onCreate never runs, so the quest cannot repair itself and the train ride
-- (which is now fully server driven) never starts. SurvivalGame always runs, so the repair lives here:
-- drop the bad entry and recreate the quest object, which then applies its normal recovery.
function SurvivalGame.sv_repairBosstrainQuestIfStuck( self )
	local questName = "quest_bosstrain"
	local successorName = "quest_endgame"

	if not ( g_questManagerServer and g_questManagerServer.sv and g_questManagerServer.sv.saved ) then
		return
	end
	local saved = g_questManagerServer.sv.saved
	saved.activeQuests = saved.activeQuests or {}
	saved.completedQuests = saved.completedQuests or {}

	local function commit()
		g_questManagerServer.storage:save( saved )
		g_questManagerServer.network:setClientData( saved )
	end

	-- Case 1: listed as active, but the quest object does not exist (orphaned save entry).
	local activeQuest = saved.activeQuests[questName]
	if activeQuest ~= nil then
		local alive = true
		local ok, result = pcall( sm.exists, activeQuest )
		if ok then
			alive = result
		end
		if not alive then
			saved.activeQuests[questName] = nil
			commit()
			printf( "SurvivalGame: dropped stale active entry for '%s'; recreating the quest object", questName )
			QuestManager.Sv_ActivateQuest( questName, nil, true )
		end
		return
	end

	-- Case 2: flagged as completed, but the successor quest never started.
	if not QuestManager.Sv_IsQuestComplete( questName ) then
		return
	end
	if QuestManager.Sv_IsQuestActive( successorName ) or QuestManager.Sv_IsQuestComplete( successorName ) then
		return
	end

	local removed = false
	for index = #saved.completedQuests, 1, -1 do
		if saved.completedQuests[index] == questName then
			table.remove( saved.completedQuests, index )
			removed = true
		end
	end
	if not removed then
		return
	end

	commit()
	printf( "SurvivalGame: '%s' was flagged complete without '%s'; recreating the quest object", questName, successorName )
	QuestManager.Sv_ActivateQuest( questName, nil, true )
end

function SurvivalGame.server_onDestroy( self )



end

function SurvivalGame.server_onRefresh( self ) --debug function for hot reload
	g_craftingRecipeSets = nil
	self:loadCraftingRecipes()
end

function SurvivalGame.server_onUnload( self )
	-- Tile storage uses deferred refs (sm.storage.saveRefDeferred) and is written by the engine
	-- during shutdown, so there is nothing to flush here. TileStorageManager.Sv_Save() no longer
	-- exists in 1.0.7.894.
end

function SurvivalGame.client_onCreate( self )
	g_isDedicatedServer = false
	self.cl = {
		time = {
			timeOfDay = 0.0,
			timeProgress = true
		}
	}

	local time = self.cl.time
	if sm.isHost then
		local sv_time = self.sv.time
		if sv_time and sv_time.timeOfDay then
			time.timeOfDay = sv_time.timeOfDay
		else
			local saved_time = sm.storage.load( STORAGE_CHANNEL_TIME )
			if saved_time and saved_time.timeOfDay then
				time.timeOfDay = saved_time.timeOfDay
			else
				sm.log.error("WHERE IS MY TIME!>!!!?!??@#?!") --written out of anger lolololol
			end
		end
	end


	if sm.isHost then
		sm.game.setTimeOfDay( math.fmod( self.cl.time.timeOfDay, 1 ) )
	end
	
	self.cl.overworld = nil
	self.cl.gotoLocations = {}

	if not sm.isHost then
		self:loadCraftingRecipes()
		g_enableCollisionTumble = true
	end

	WorldManager.Cl_OnCreate()

	if g_respawnManager == nil then
		assert( not sm.isHost )
		g_respawnManager = RespawnManager()
	end
	g_respawnManager:cl_onCreate()

	if g_beaconManager == nil then
		assert( not sm.isHost )
		g_beaconManager = BeaconManager()
	end
	g_beaconManager:cl_onCreate()

	if g_unitManager == nil then
		assert( not sm.isHost )
		g_unitManager = UnitManager()
	end

	g_radioTransmitter = sm.effect.createEffect( "Radio - Transmitter" )
	g_radioTransmitter:setWorldAny()
	g_boomboxTransmitter = sm.effect.createEffect( "Boombox - Transmitter" )
	g_boomboxTransmitter:setWorldAny()

	-- Survival HUD
	g_survivalHud = sm.gui.createSurvivalHudGui()
	assert(g_survivalHud)
	g_survivalHud:setVisible( "StatusPanel", false )
	g_survivalHud:setVisible( "BreathPanel", false )

	-- Compass HUD
	self.cl.compassEnabled = sm.game.getSettingBoolean( "CompassHud" )
	g_compassHud = sm.gui.createCompassHudGui()
	assert(g_compassHud)
	self:cl_compassHudEnable( self.cl.compassEnabled )

	self.cl.renderManager = sm.clientScriptableObject.createScriptableObject( sm.uuid.new( "54563daa-dd25-4f43-9e49-7e58bd59f66a" ) )




end

function SurvivalGame.bindChatCommands( self )
	sm.game.bindChatCommand( "/getMyId", {}, "cl_onChatCommand", "Print your player id" )
	sm.game.bindChatCommand( "/kick", { { "string", "player name", false } }, "cl_onChatCommand", "Kick a player from server" )
	sm.game.bindChatCommand( "/ban", { { "string", "player name", false } }, "cl_onChatCommand", "Ban a player from server" )
	sm.game.bindChatCommand( "/unban", { { "string", "player name", false } }, "cl_onChatCommand", "Ban a player from server" )

	-- smserver commands (server-side admin check in sv_onChatCommand)
	sm.game.bindChatCommand( "/op", { { "int", "player id", false }, { "bool", "enable", true } }, "cl_onChatCommand", "Grant or revoke administrator rights" )
	sm.game.bindChatCommand( "/ender", { { "string", "player name", true } }, "cl_onChatCommand", "Open a public or player ender chest" )
	sm.game.bindChatCommand( "/tp", { { "string", "player name", false } }, "cl_onChatCommand", "Teleport to a player" )
	sm.game.bindChatCommand( "/tpr", { { "string", "player name", false } }, "cl_onChatCommand", "Teleport a player to you" )
	sm.game.bindChatCommand( "/tpp", { { "number", "x", false }, { "number", "y", false }, { "number", "z", false } }, "cl_onChatCommand", "Teleport to coordinates in your current world" )
	sm.game.bindChatCommand( "/give", { { "string", "item uuid", false }, { "int", "quantity", true } }, "cl_onChatCommand", "Give yourself an item" )
	sm.game.bindChatCommand( "/spawnpart", { { "string", "part uuid", false } }, "cl_onChatCommand", "Spawn a part in front of you" )
	sm.game.bindChatCommand( "/ppos", {}, "cl_onChatCommand", "Print your position" )
	sm.game.bindChatCommand( "/listPlayers", {}, "cl_onChatCommand", "List connected players with their ids" )
	sm.game.bindChatCommand( "/unlimited", {}, "cl_onChatCommand", "Use the unlimited inventory" )
	sm.game.bindChatCommand( "/limited", {}, "cl_onChatCommand", "Use the limited inventory" )
	-- quest commands
	sm.game.bindChatCommand( "/quest", { { "string", "action", true }, { "string", "questName", true } }, "cl_onChatCommand", "Manage quests: list, start, complete, abandon, reset" )
	sm.game.bindChatCommand( "/unlockkey", { { "string", "keyName", true } }, "cl_onChatCommand", "Unlock a progression log/key: all, elevator, accesscard_01..04, minerboss" )
	sm.game.bindChatCommand( "/unlockelevator", { { "string", "target", true } }, "cl_onChatCommand", "Unlock main-elevator tier(s): all, scrapyard, or 0..8" )
	sm.game.bindChatCommand( "/elevator", { { "string", "floor", true } }, "cl_onChatCommand", "Force the MAIN elevator to a floor by index or name" )
	
	sm.game.bindChatCommand( "/setHostExcluded", {{"bool", "", false, {"true", "false"}}}, "cl_onChatCommand", "Set g_excludeHostPlayer" )



	--local addCheats = g_survivalDev

	--if addCheats then
		sm.game.bindChatCommand( "/ammo", { { "int", "quantity", true } }, "cl_onChatCommand", "Give ammo (default 100)" )
		sm.game.bindChatCommand( "/spudgun", {}, "cl_onChatCommand", "Give the spudgun" )
		sm.game.bindChatCommand( "/gatling", {}, "cl_onChatCommand", "Give the potato gatling gun" )
		sm.game.bindChatCommand( "/shotgun", {}, "cl_onChatCommand", "Give the fries shotgun" )
		sm.game.bindChatCommand( "/sunshake", {}, "cl_onChatCommand", "Give 1 sunshake" )
		sm.game.bindChatCommand( "/baguette", {}, "cl_onChatCommand", "Give 1 revival baguette" )
		sm.game.bindChatCommand( "/keycard", {}, "cl_onChatCommand", "Give 1 keycard" )
		sm.game.bindChatCommand( "/powercore", {}, "cl_onChatCommand", "Give 1 powercore" )
		sm.game.bindChatCommand( "/components", { { "int", "quantity", true } }, "cl_onChatCommand", "Give <quantity> components (default 10)" )
		sm.game.bindChatCommand( "/glowsticks", { { "int", "quantity", true } }, "cl_onChatCommand", "Give <quantity> components (default 10)" )
		sm.game.bindChatCommand( "/foodplease", {}, "cl_onChatCommand", "Give 5 of each edible type" )
		sm.game.bindChatCommand( "/seedsplease", {}, "cl_onChatCommand", "Give 20 of each seed type and some soil" )
		sm.game.bindChatCommand( "/tumble", { { "bool", "enable", true } }, "cl_onChatCommand", "Set tumble state" )
		sm.game.bindChatCommand( "/god", {}, "cl_onChatCommand", "Mechanic characters will take no damage" )
		sm.game.bindChatCommand( "/limited", {}, "cl_onChatCommand", "Use the limited inventory" )
		sm.game.bindChatCommand( "/unlimited", {}, "cl_onChatCommand", "Use the unlimited inventory" )
		sm.game.bindChatCommand( "/timeofday", { { "number", "timeOfDay", true } }, "cl_onChatCommand", "Sets the time of the day as a fraction (0.5=mid day)" )
		sm.game.bindChatCommand( "/timeprogress", { { "bool", "enabled", true } }, "cl_onChatCommand", "Enables or disables time progress" )
		
		
		local autocomplete = {}
		for k, _ in pairs( g_unitSpawnNames ) do
			autocomplete[#autocomplete+1] = k
		end
		sm.game.bindChatCommand( "/spawn", { { "string", "unitName", true, autocomplete }, { "int", "amount", true } }, "cl_onChatCommand", "Spawn a unit: 'woc', 'tapebot', 'totebot', 'haybot'" )

		local existingKits = { "start", "trashbot", "mechanic", "tutorial", "pipe", "food", "seed" }
		
		sm.game.bindChatCommand( "/starterkit", { { "string", "name", true, existingKits } }, "cl_onChatCommand", "Spawn a starter kit" )
		sm.game.bindChatCommand( "/die", {}, "cl_onChatCommand", "Kill the player" )
		sm.game.bindChatCommand( "/unstuck", {}, "cl_onChatCommand", "Unstuck the player" )
		sm.game.bindChatCommand( "/sethp", { { "number", "hp", false } }, "cl_onChatCommand", "Set player hp value" )
		sm.game.bindChatCommand( "/setbreath", { { "number", "breath", false } }, "cl_onChatCommand", "Set player breath value" )
		sm.game.bindChatCommand( "/aggroall", {}, "cl_onChatCommand", "All hostile units will be made aware of the player's position" )
		
		sm.game.bindChatCommand( "/stopraid", {}, "cl_onChatCommand", "Cancel all incoming raids" )
		sm.game.bindChatCommand( "/disableraids", { { "bool", "enabled", false } }, "cl_onChatCommand", "Disable raids if true" )
		sm.game.bindChatCommand( "/noaggro", { { "bool", "enable", true } }, "cl_onChatCommand", "Toggles the player as a target" )
		sm.game.bindChatCommand( "/exportmultishape", {}, "cl_onChatCommand", "Exports a blueprint shape file" )
	--end
end

function SurvivalGame.client_onClientDataUpdate( self, clientData, channel )
	if channel == 2 then
		self.cl.time = clientData.time
	elseif channel == 1 then
		g_survivalDev = clientData.dev
		self.cl.gotoLocations = clientData.gotoLocations
		self:bindChatCommands()
	end
end


function SurvivalGame.loadCraftingRecipes( self )
	local recipeSets = sm.json.open( "$SURVIVAL_DATA/CraftingRecipes/craftbot/craftbot.json" )
	recipeSets.workbench = "$SURVIVAL_DATA/CraftingRecipes/workbench.json"
	recipeSets.portablecrafter = "$SURVIVAL_DATA/CraftingRecipes/portablecrafter.json"
	recipeSets.dispenser = "$SURVIVAL_DATA/CraftingRecipes/dispenser.json"
	recipeSets.cookbot = "$SURVIVAL_DATA/CraftingRecipes/cookbot.json"
	recipeSets.dressbot = "$SURVIVAL_DATA/CraftingRecipes/dressbot.json"
	recipeSets.mininghubDispenser = "$SURVIVAL_DATA/CraftingRecipes/mininghubDispenser.json"
	recipeSets.sawtable = "$SURVIVAL_DATA/CraftingRecipes/sawtable.json"
	recipeSets.craftbot_custom = "$CONTENT_DATA/CraftingRecipes/craftbot/craftbot_custom.json"
	for setName, path in pairs( {
		craftbot_scomputers = "$CONTENT_3aeb81c2-71b9-45a1-9479-1f48f1e8ff21/CraftingRecipes/craftbot.json",
		craftbot_modpack = "$CONTENT_DATA/CraftingRecipes/dependencies/craftbot_modpack.json",
	} ) do
		if sm.json.fileExists( path ) then
			recipeSets[setName] = path
		end
	end

	-- The first time a new JSON file is opened the engine builds its const-data
	-- cache and sm.json.open can fail. Retry so a fresh install does not need a
	-- second world start before the custom recipes work.
	for _ = 1, 3 do
		local ok = pcall( LoadCraftingRecipes, recipeSets )
		if ok and g_craftingRecipeSets and g_craftingRecipeSets.craftbot_custom then
			break
		end
	end

	-- print() only reaches the game log with -dev, so the load outcome goes through
	-- sm.log instead: a cold const-data cache used to fail silently for a whole run.
	if g_craftingRecipeSets and g_craftingRecipeSets.craftbot_custom then
		sm.log.info( "SMSERVER: custom recipe sets loaded" )
	else
		sm.log.error( "SMSERVER: craftbot_custom recipe set failed to load" )
	end

	-- Remove production-blacklisted items from every loaded recipe set before
	-- the recipe manager builds its unlock lists.
	local blockedRecipeCount = 0
	if g_craftingRecipeSets then
		for _, recipeSet in pairs( g_craftingRecipeSets ) do
			local kept = {}
			for _, recipe in ipairs( recipeSet.recipesByIndex ) do
				if smserver_isBlockedItem( recipe.itemId ) then
					recipeSet.recipes[recipe.itemId] = nil
					blockedRecipeCount = blockedRecipeCount + 1
				else
					kept[#kept + 1] = recipe
				end
			end
			recipeSet.recipesByIndex = kept
		end
	end
	if blockedRecipeCount > 0 then
		sm.log.warning( "SMSERVER removed " .. tostring( blockedRecipeCount ) .. " blacklisted recipes" )
	end
	if g_crafterItems then
		for itemId in pairs( g_crafterItems ) do
			if smserver_isBlockedItem( itemId ) then
				g_crafterItems[itemId] = nil
			end
		end
	end
	if g_unlockableCraftItems then
		for itemId in pairs( g_unlockableCraftItems ) do
			if smserver_isBlockedItem( itemId ) then
				g_unlockableCraftItems[itemId] = nil
			end
		end
	end
end

function SurvivalGame.server_onFixedUpdate( self, timeStep )
	if self.sv.bosstrainRepairTick then
		if sm.game.getCurrentTick() >= self.sv.bosstrainRepairTick then
			self.sv.bosstrainRepairTick = nil
			self:sv_repairBosstrainQuestIfStuck()
		end
	end

	if self.sv.raidManagerCheckTick then
		if sm.game.getCurrentTick() >= self.sv.raidManagerCheckTick then
			self.sv.raidManagerCheckTick = nil
			if g_raidManager then
				-- printf() is print(), and print() only reaches the log with -dev.
				sm.log.info( "SMSERVER: RaidManager ready" )
			else
				sm.log.error( "SMSERVER: RaidManager scriptable object is missing; raids cannot start" )
			end
		end
	end
	--probably needed for later checks lol
	--[[
	if self.sv.hostProbeTick then
		if sm.game.getCurrentTick() >= self.sv.hostProbeTick then
			self.sv.hostProbeTick = nil
			local ok, host = pcall(sm.player.getHostPlayer)
			local hostText = "error"
			if ok then
				if host == nil then
					hostText = "nil"
				else
					hostText = "id=" .. tostring( host.id ) .. " name=" .. tostring( host.name )
				end
			end
			printf( "SMSERVER host probe: isHost=%s getHostPlayer=%s players=%d",
				tostring( sm.isHost ), hostText, #sm.player.getAllPlayers() )
			-- printf() is print(); only sm.log is written to the log without -dev.
			sm.log.info( "SMSERVER host probe: isHost=" .. tostring( sm.isHost )
				.. " getHostPlayer=" .. hostText
				.. " players=" .. tostring( #sm.player.getAllPlayers() ) )
		end
	end
	]]
	-- Temporary raid diagnostics: every 10 s report where each raid stands.
	-- A dedicated run needs this because the raid manager is a stock scriptable
	-- object and cannot log anything of its own without patching stock code.
	--[[	
	if g_raidManager and g_raidManager.sv and g_raidManager.sv.saved then
		local currentTick = sm.game.getCurrentTick()
		if not self.sv.raidProbeTick or currentTick >= self.sv.raidProbeTick then
			self.sv.raidProbeTick = currentTick + 400
			for worldId, raids in pairs( g_raidManager.sv.saved.worldRaids or {} ) do
				for raidKey, raid in pairs( raids ) do
					local attackData = raid.attackData or {}
					local spawned, total = 0, 0
					for _, group in ipairs( attackData.groupSpawns or {} ) do
						total = total + 1
						if group.isSpawned then
							spawned = spawned + 1
						end
					end
					local raiderCount = 0
					for _ in pairs( raid.raiders or {} ) do
						raiderCount = raiderCount + 1
					end
					
					sm.log.info( "SMSERVER raid", raidKey,
						"world=", worldId,
						"tick=", currentTick,
						"attackTick=", attackData.attackTick,
						"attackStartTick=", raid.attackStartTick,
						"spawnPoints=", attackData.spawnPositions ~= nil,
						"groups=", spawned, "/", total,
						"raiders=", raiderCount,
						"enemiesLeft=", raid.enemiesLeft,
						"players=", #sm.player.getAllPlayers() )
				end
			end
		end
	end
	]]
	-- Custom and dependency recipes are craftable from the start; there is no
	-- schematic source for them.
	if g_recipeManager and g_craftingRecipeSets then
		for _, setName in ipairs( { "craftbot_custom", "craftbot_scomputers", "craftbot_modpack" } ) do
			local recipeSet = g_craftingRecipeSets[setName]
			if recipeSet then
				for itemId in pairs( recipeSet.recipes ) do
					local itemIdString = tostring( itemId )
					if not RecipeManager.Sv_IsUnlocked( itemIdString ) then
						RecipeManager.Sv_UnlockRecipe( itemIdString, true )
					end
				end
			end
		end
	end

	-- Update time







		if self.sv.time.timeProgress then
			self.sv.time.timeOfDay = self.sv.time.timeOfDay + ( timeStep / DAYCYCLE_TIME )
		end




	if WeatherManager.Get() then
		WeatherManager.Get():sv_setTimeOfDay( self.cl.time.timeOfDay )
	end

	-- Client and save sync
	self.sv.syncTimer:tick()
	if self.sv.syncTimer:done() then
		self.sv.syncTimer:start( SyncInterval )
		sm.storage.saveAndSync( STORAGE_CHANNEL_TIME, self.sv.time )
		self:sv_updateClientData()
	end

	g_unitManager:sv_onFixedUpdate()

	if g_respawnManager then
		g_respawnManager:sv_onFixedUpdate()
	end
end

function SurvivalGame.sv_updateClientData( self, ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	self.network:setClientData( { time = self.sv.time }, 2 )
end

function SurvivalGame.client_onUpdate( self, dt )
	-- Update time







		if self.cl.time.timeProgress then
			self.cl.time.timeOfDay = self.cl.time.timeOfDay + ( dt / DAYCYCLE_TIME )
		end




	if WeatherManager.Get() then
		WeatherManager.Get():cl_setTimeOfDay( self.cl.time.timeOfDay )
	end

	local todWraped = math.fmod( self.cl.time.timeOfDay, 1 )
	sm.game.setTimeOfDay( todWraped )

	-- Update lighting values
	local index = 1
	while index < #DAYCYCLE_LIGHTING_TIMES and todWraped >= DAYCYCLE_LIGHTING_TIMES[index + 1] do
		index = index + 1
	end
	assert( index <= #DAYCYCLE_LIGHTING_TIMES )

	local light = 0.0
	if index < #DAYCYCLE_LIGHTING_TIMES then
		local p = ( todWraped - DAYCYCLE_LIGHTING_TIMES[index] ) / ( DAYCYCLE_LIGHTING_TIMES[index + 1] - DAYCYCLE_LIGHTING_TIMES[index] )
		light = sm.util.lerp( DAYCYCLE_LIGHTING_VALUES[index], DAYCYCLE_LIGHTING_VALUES[index + 1], p )
	else
		light = DAYCYCLE_LIGHTING_VALUES[index]
	end
	
	sm.render.setOutdoorLighting( light )




end

function SurvivalGame.client_onFixedUpdate( self, dt )

	local compassSetting = sm.game.getSettingBoolean( "CompassHud" )
	if self.cl.compassEnabled ~= compassSetting then
		self.cl.compassEnabled = compassSetting
		self:cl_compassHudEnable( self.cl.compassEnabled )
	end
end

function SurvivalGame.cl_compassHudEnable( self, enable )
	if enable == true then
		g_compassHud:open()
	else
		g_compassHud:close()
	end
end

function SurvivalGame.client_showMessage( self, msg )
	sm.gui.chatMessage( msg )
end

function SurvivalGame.cl_onChatCommand( self, params )

	-- stop panic, its's 
	if params[1] == "/getMyId" then
		sm.gui.chatMessage( "Your player ID is: " .. tostring( sm.localPlayer.getId() ) )
		
	elseif params[1] == "/listPlayers" then
		for _, player in ipairs( sm.player.getAllPlayers() ) do
			sm.gui.chatMessage(string.format("[%s] %s", player.id, player.name))
		end
	elseif params[1] == "/ammo" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = obj_plantables_potato, quantity = ( params[2] or 100 ) } )
	elseif params[1] == "/spudgun" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = tool_spudgun, quantity = 1 } )
	elseif params[1] == "/gatling" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = tool_gatling, quantity = 1 } )
	elseif params[1] == "/shotgun" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = tool_shotgun, quantity = 1 } )
	elseif params[1] == "/sunshake" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = obj_consumable_sunshake, quantity = 1 } )
	elseif params[1] == "/baguette" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = obj_consumable_longsandwich, quantity = 1 } )
	elseif params[1] == "/keycard" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = obj_survivalobject_keycard, quantity = 1 } )
	elseif params[1] == "/powercore" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = obj_survivalobject_powercore, quantity = 1 } )
	elseif params[1] == "/components" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = obj_consumable_component, quantity = ( params[2] or 10 ) } )
	elseif params[1] == "/glowsticks" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = obj_consumable_glowstick, quantity = ( params[2] or 20 ) } )
	elseif params[1] == "/foodplease" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_resource_corn, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_plantables_tomato, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_plantables_carrot, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_plantables_redbeet, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_plantables_banana, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_plantables_blueberry, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_plantables_orange, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_plantables_broccoli, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_plantables_pineapple, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_consumable_milk, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_consumable_pizzaburger, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_consumable_carrotburger, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_consumable_sunshake, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_consumable_tea, quantity = 5 } )
	elseif params[1] == "/seedsplease" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_consumable_soilbag, quantity = 5 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_potato, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_tomato, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_carrot, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_redbeet, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_banana, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_blueberry, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_orange, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_broccoli, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_pineapple, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_chili, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_pigmentflower, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_seed_cotton, quantity = 20 } )
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = ITEMS.obj_consumable_soilbag, quantity = 45 } )
	elseif params[1] == "/god" then
		self.network:sendToServer( "sv_switchGodMode" )
	elseif params[1] == "/unlimited" then
		self.network:sendToServer( "sv_setLimitedInventory", false )
	elseif params[1] == "/limited" then
		self.network:sendToServer( "sv_setLimitedInventory", true )
	elseif params[1] == "/timeofday" then
		self.network:sendToServer( "sv_setTimeOfDay", params[2] )
	elseif params[1] == "/timeprogress" then
		self.network:sendToServer( "sv_setTimeProgress", params[2] )
	elseif params[1] == "/die" then
		self.network:sendToServer( "sv_killPlayer", { player = sm.localPlayer.getPlayer() } )
	elseif params[1] == "/unstuck" then
		sm.event.sendToPlayer( sm.localPlayer.getPlayer(), "cl_e_unstuck" )
	elseif params[1] == "/spawn" then
		local rayCastValid, rayCastResult = sm.localPlayer.getRaycast( 100 )
		if rayCastValid then
			local spawnParams = {
				uuid = sm.uuid.getNil(),
				world = sm.localPlayer.getPlayer().character:getWorld(),
				position = rayCastResult.pointWorld,
				yaw = 0.0,
				amount = 1,
				customParams = { tetherPoint = rayCastResult.pointWorld }
			}
			if g_unitSpawnNames[params[2]] then
				spawnParams.uuid = g_unitSpawnNames[params[2]]
			else
				spawnParams.uuid = sm.uuid.new( params[2] )
			end
			if params[3] then
				spawnParams.amount = params[3]
			end
			self.network:sendToServer( "sv_spawnUnit", spawnParams )
		end
	
	
	elseif params[1] == "/noaggro" then
		if type( params[2] ) == "boolean" then
			self.network:sendToServer( "sv_n_switchAggroMode", { aggroMode = not params[2] } )
		else
			self.network:sendToServer( "sv_n_switchAggroMode", { aggroMode = not sm.game.getEnableAggro() } )
		end
	elseif params[1] == "/quest" then
		self.network:sendToServer( "sv_manageQuest", { action = params[2] or "list", questName = params[3] } )
	elseif params[1] == "/unlockkey" then
		self.network:sendToServer( "sv_unlockProgressionKey", { keyName = params[2] or "all" } )
	elseif params[1] == "/unlockelevator" then
		self.network:sendToServer( "sv_unlockElevatorDepth", { target = params[2] or "all" } )
	elseif params[1] == "/elevator" then
		self.network:sendToServer( "sv_forceElevatorFloor", { target = params[2] } )
	else
		self.network:sendToServer( "sv_onChatCommand", params )
	end
end

function SurvivalGame.sv_manageQuest( self, params, ... )

	local function BuildProgressionKeyMap()
		local keys = {
			["all"] = {
				LOGS.log_underground_elevator_key_01,
				LOGS.log_accesscard_01,
				LOGS.log_accesscard_02,
				LOGS.log_accesscard_03,
				LOGS.log_accesscard_04,
				LOGS.log_underground_minerboss_key,
			},
			["elevator"] = { LOGS.log_underground_elevator_key_01 },
			["underground_elevator_key_01"] = { LOGS.log_underground_elevator_key_01 },
			["accesscard_01"] = { LOGS.log_accesscard_01 },
			["accesscard_02"] = { LOGS.log_accesscard_02 },
			["accesscard_03"] = { LOGS.log_accesscard_03 },
			["accesscard_04"] = { LOGS.log_accesscard_04 },
			["accesscard"] = { LOGS.log_accesscard_01, LOGS.log_accesscard_02, LOGS.log_accesscard_03, LOGS.log_accesscard_04 },
			["minerboss"] = { LOGS.log_underground_minerboss_key },
			["underground_minerboss_key"] = { LOGS.log_underground_minerboss_key },
		}
		return keys
	end

	local function UnlockMainElevatorProgression( targetDepth )
		local floors = UNDERGROUND_ELEVATORS and UNDERGROUND_ELEVATORS["MAIN"] and UNDERGROUND_ELEVATORS["MAIN"].floors or nil
		if floors == nil then
			return 0, {}
		end

		local maxDepth = math.huge
		if type( targetDepth ) == "number" then
			maxDepth = targetDepth
		end

		local granted = {}
		for _, floor in ipairs( floors ) do
			if floor and floor.depth ~= nil and floor.depth <= maxDepth then
				ProgressionManager.Sv_SetReachedUndergroundDepth( floor.depth )
			end
			if floor and floor.requiresKey and type( floor.requiresKey ) == "string" and floor.depth <= maxDepth then
				if not LogEntryManager.Sv_HasLog( floor.requiresKey ) then
					LogEntryManager.Sv_AddLog( floor.requiresKey, true )
				end
				granted[#granted + 1] = floor.requiresKey
			end
		end
		return #granted, granted
	end

	local function UnlockedProgressionKey( keyName )
		local keyMap = BuildProgressionKeyMap()
		local uuids = keyMap[keyName]
		if not uuids then
			return false, "Unknown progression key: " .. tostring( keyName ) .. ". Use: all, elevator, accesscard_01..04, minerboss"
		end

		local granted = {}
		for _, uuid in ipairs( uuids ) do
			if not LogEntryManager.Sv_HasLog( uuid ) then
				LogEntryManager.Sv_AddLog( uuid, true )
			end
			granted[#granted + 1] = uuid
		end
		return true, #granted
	end

	local function UnlockElevatorDepth( target )
		local mainElevator = g_undergroundElevatorManager and g_undergroundElevatorManager.elevators and g_undergroundElevatorManager.elevators["MAIN"]
		if target == "scrapyard" then
			if mainElevator then
				mainElevator.scrapyardUnlocked = true
				g_undergroundElevatorManager:sv_saveElevators()
			end
			ProgressionManager.Sv_SetReachedUndergroundDepth( 5 )
			return true, "Scrapyard unlock force-enabled on the main elevator."
		end

		local depthLimit = nil
		if target ~= "all" then
			depthLimit = tonumber( target )
			if depthLimit == nil then
				return false, "Usage: /unlockelevator <all|scrapyard|0..8>"
			end
			if depthLimit < 0 then
				depthLimit = 0
			end
		end

		if target == "all" then
			depthLimit = math.huge
		end

		local count = UnlockMainElevatorProgression( depthLimit )
		if mainElevator and target == "all" then
			mainElevator.scrapyardUnlocked = true
			g_undergroundElevatorManager:sv_saveElevators()
		end
		return true, "Main elevator progression unlocked for " .. tostring( count ) .. " required key(s)."
	end

	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end

	local action = string.lower( tostring( params and params.action or "list" ) )
	if action == "list" then
		local questNames = {}
		if g_questManagerServer and g_questManagerServer.sv and g_questManagerServer.sv.quests then
			for questName in pairs( g_questManagerServer.sv.quests ) do
				questNames[#questNames + 1] = questName
			end
			table.sort( questNames )
		end
		self.network:sendToClients( "client_showMessage", "Quest list: " .. ( #questNames > 0 and table.concat( questNames, ", " ) or "none" ) )
		return
	end

	if not params or not params.questName or params.questName == "" then
		self.network:sendToClients( "client_showMessage", "Usage: /quest <list|start|complete|abandon|reset> <questName>" )
		return
	end

	local questName = params.questName
	if not g_questManagerServer or not g_questManagerServer.sv or not g_questManagerServer.sv.quests or g_questManagerServer.sv.quests[questName] == nil then
		self.network:sendToClients( "client_showMessage", "Unknown quest: " .. tostring( questName ) )
		return
	end

	local message = "Quest command failed: " .. questName
	if action == "start" then
		if QuestManager.Sv_IsQuestActive( questName ) then
			message = "Quest already active: " .. questName
		elseif QuestManager.Sv_IsQuestComplete( questName ) then
			message = "Quest already complete: " .. questName
		else
			QuestManager.Sv_ActivateQuest( questName )
			message = "Started quest: " .. questName
		end
	elseif action == "complete" then
		if QuestManager.Sv_IsQuestActive( questName ) then
			QuestManager.Sv_CompleteQuest( questName )
			message = "Completed quest: " .. questName
		elseif QuestManager.Sv_IsQuestComplete( questName ) then
			message = "Quest already complete: " .. questName
		else
			message = "Quest is not active: " .. questName
		end
	elseif action == "abandon" then
		if QuestManager.Sv_IsQuestActive( questName ) then
			QuestManager.Sv_AbandonQuest( questName )
			message = "Abandoned quest: " .. questName
		else
			message = "Quest is not active: " .. questName
		end
	elseif action == "reset" then
		if QuestManager.Sv_IsQuestActive( questName ) then
			QuestManager.Sv_AbandonQuest( questName )
		end
		if g_questManagerServer and g_questManagerServer.sv and g_questManagerServer.sv.saved then
			for i = #g_questManagerServer.sv.saved.completedQuests, 1, -1 do
				if g_questManagerServer.sv.saved.completedQuests[i] == questName then
					table.remove( g_questManagerServer.sv.saved.completedQuests, i )
				end
			end
			g_questManagerServer.storage:save( g_questManagerServer.sv.saved )
			g_questManagerServer.network:setClientData( g_questManagerServer.sv.saved )
		end
		message = "Reset quest state: " .. questName
	else
		message = "Unknown quest action: " .. action .. ". Use list, start, complete, abandon or reset."
	end

	self.network:sendToClients( "client_showMessage", message )
end

function SurvivalGame.sv_unlockProgressionKey( self, params, ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end

	local keyName = string.lower( tostring( params and params.keyName or "all" ) )
	local keyMap = {
		["all"] = {
			LOGS.log_underground_elevator_key_01,
			LOGS.log_accesscard_01,
			LOGS.log_accesscard_02,
			LOGS.log_accesscard_03,
			LOGS.log_accesscard_04,
			LOGS.log_underground_minerboss_key,
		},
		["elevator"] = { LOGS.log_underground_elevator_key_01 },
		["underground_elevator_key_01"] = { LOGS.log_underground_elevator_key_01 },
		["accesscard_01"] = { LOGS.log_accesscard_01 },
		["accesscard_02"] = { LOGS.log_accesscard_02 },
		["accesscard_03"] = { LOGS.log_accesscard_03 },
		["accesscard_04"] = { LOGS.log_accesscard_04 },
		["accesscard"] = { LOGS.log_accesscard_01, LOGS.log_accesscard_02, LOGS.log_accesscard_03, LOGS.log_accesscard_04 },
		["minerboss"] = { LOGS.log_underground_minerboss_key },
		["underground_minerboss_key"] = { LOGS.log_underground_minerboss_key },
	}
	local uuids = keyMap[keyName]
	if not uuids then
		self.network:sendToClients( "client_showMessage", "Unknown progression key: " .. tostring( keyName ) .. ". Use: all, elevator, accesscard_01..04, minerboss" )
		return
	end

	local granted = {}
	for _, uuid in ipairs( uuids ) do
		if not LogEntryManager.Sv_HasLog( uuid ) then
			LogEntryManager.Sv_AddLog( uuid, true )
		end
		granted[#granted + 1] = uuid
	end

	self.network:sendToClients( "client_showMessage", "Unlocked progression key(s): " .. tostring( #granted ) )
end

function SurvivalGame.sv_unlockElevatorDepth( self, params, ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end

	local target = string.lower( tostring( params and params.target or "all" ) )
	local mainElevator = g_undergroundElevatorManager and g_undergroundElevatorManager.elevators and g_undergroundElevatorManager.elevators["MAIN"]

	if target == "scrapyard" then
		if mainElevator then
			mainElevator.scrapyardUnlocked = true
			g_undergroundElevatorManager:sv_saveElevators()
		end
		ProgressionManager.Sv_SetReachedUndergroundDepth( 5 )
		self.network:sendToClients( "client_showMessage", "Scrapyard unlock force-enabled on the main elevator." )
		return
	end

	local depthLimit = nil
	if target ~= "all" then
		depthLimit = tonumber( target )
		if depthLimit == nil then
			self.network:sendToClients( "client_showMessage", "Usage: /unlockelevator <all|scrapyard|0..8>" )
			return
		end
		if depthLimit < 0 then
			depthLimit = 0
		end
	end

	if target == "all" then
		depthLimit = math.huge
	end

	local floors = UNDERGROUND_ELEVATORS and UNDERGROUND_ELEVATORS["MAIN"] and UNDERGROUND_ELEVATORS["MAIN"].floors or nil
	if floors ~= nil then
		for _, floor in ipairs( floors ) do
			if floor and floor.depth ~= nil and depthLimit ~= nil and floor.depth <= depthLimit then
				ProgressionManager.Sv_SetReachedUndergroundDepth( floor.depth )
			end
			if floor and floor.requiresKey and type( floor.requiresKey ) == "string" and ( depthLimit == nil or floor.depth <= depthLimit ) then
				if not LogEntryManager.Sv_HasLog( floor.requiresKey ) then
					LogEntryManager.Sv_AddLog( floor.requiresKey, true )
				end
			end
		end
	end

	if mainElevator and target == "all" then
		mainElevator.scrapyardUnlocked = true
		g_undergroundElevatorManager:sv_saveElevators()
	end

	self.network:sendToClients( "client_showMessage", "Main elevator progression unlocked." )
end

local function ResolveMainElevatorFloorIndex( target )
	local floors = UNDERGROUND_ELEVATORS and UNDERGROUND_ELEVATORS["MAIN"] and UNDERGROUND_ELEVATORS["MAIN"].floors
	if floors == nil or target == nil then
		return nil
	end
	local text = string.lower( tostring( target ) )
	text = string.gsub( text, "^%s+", "" )
	text = string.gsub( text, "%s+$", "" )
	if text == "" then
		return nil
	end

	local number = tonumber( text )
	if number == nil then
		number = tonumber( string.match( text, "^floor%s*(%d+)$" ) or "" )
	end
	if number ~= nil then
		number = math.floor( number )
		if number >= 1 and number <= #floors then
			return number
		end
		return nil
	end

	for index, floor in ipairs( floors ) do
		if floor.debug and string.find( string.lower( floor.debug ), text, 1, true ) then
			return index
		end
	end
	return nil
end

function SurvivalGame.sv_forceElevatorFloor( self, params, ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller == nil or not smserver_isAdmin( caller ) then
		return
	end

	local manager = g_undergroundElevatorManager
	if manager == nil or manager.elevators == nil then
		self.network:sendToClient( caller, "client_showMessage", "Elevator manager is not ready." )
		return
	end
	local elevator = manager.elevators["MAIN"]
	if elevator == nil then
		self.network:sendToClient( caller, "client_showMessage", "MAIN elevator is not registered yet." )
		return
	end

	local floorIndex = ResolveMainElevatorFloorIndex( params and params.target )
	if floorIndex == nil then
		local floorNames = {}
		for index, floor in ipairs( UNDERGROUND_ELEVATORS["MAIN"].floors ) do
			floorNames[#floorNames + 1] = index.."="..tostring( floor.debug )
		end
		self.network:sendToClient( caller, "client_showMessage",
			"MAIN elevator current floor: "..tostring( elevator.currentFloor )..". Usage: /elevator <1-9|name>. Floors: "..table.concat( floorNames, ", " ) )
		return
	end

	local _, message = manager:sv_requestForceFloor( "MAIN", floorIndex, caller )
	self.network:sendToClient( caller, "client_showMessage", message or "Elevator floor change requested." )
end

function SurvivalGame.sv_reloadTile( self, params , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	local xMin,xMax,yMin,yMax
	if params.pos then
		xMin,xMax,yMin,yMax = GetTileRanges( params.pos, params.world.id )
	elseif params.cell then
		xMin,xMax,yMin,yMax = GetTileRangesFromCell( params.cell.x, params.cell.y, params.world.id )
	end
	self.network:sendToClients( "cl_reloadTile", { world = params.world, xMin = xMin, xMax = xMax, yMin = yMin, yMax = yMax } )
end

function SurvivalGame.cl_reloadTile( self, params )
	for x = params.xMin, params.xMax do
		for y = params.yMin, params.yMax do
			params.world:reloadCell( x, y )
		end
	end
end

function SurvivalGame.sv_reloadCell( self, params, player )
	if player == nil or not smserver_isAdmin( player ) then
		return
	end
	self.sv.saved.overworld:loadCell( params.x, params.y, player )
	self.network:sendToClients( "cl_reloadCell", params )
end

function SurvivalGame.sv_loadCell( self, params , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	if not sm.exists( self.sv.saved.overworld ) then
		sm.world.loadWorld( self.sv.saved.overworld )
	end

	if self.handle then
		self.handle:release()
	end

	self.handle = self.sv.saved.overworld:loadCellWithHandle( params.x, params.y, nil )
end

function SurvivalGame.sv_releaseCell( self , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	if self.handle then
		self.handle:release()
		self.handle = nil
	end
end

function SurvivalGame.sv_n_chemicaltower( self , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	EffectManager.Cl_PlayNamedCinematic( { name = "cinematic.chemicaltower", callbackData = { world = self.sv.saved.overworld } } )
end

function SurvivalGame.cl_reloadCell( self, params )
	for x = -2, 2 do
		for y = -2, 2 do
			params.world:reloadCell( params.x+x, params.y+y )
		end
	end
end

function SurvivalGame.sv_giveItem( self, params , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	sm.container.beginTransaction()
	sm.container.collect( params.player:getInventory(), params.item, params.quantity, false )
	sm.container.endTransaction()
end

function SurvivalGame.cl_n_onJoined( self, params )
	self.cl.playIntroCinematic = params.newPlayer
end

function SurvivalGame.client_onLoadingScreenLifted( self )
	EffectManager.Cl_OnLoadingScreenLifted()
	TutorialManager.Cl_OnLoadingScreenLifted()

	self.network:sendToServer( "sv_n_loadingScreenLifted" )
	if self.cl.playIntroCinematic and not g_survivalDev then
		EffectManager.Cl_PlayNamedCinematic( { name = "cinematic.survivalstart01", callbackData = { world = self.cl.overworld }, forceCameraData = true } )
	end
	
	self.network:sendToServer("CHECK_ME")
end

function SurvivalGame.DESTROY_ME(self, _, caller)
	if caller and caller.id == sm.player.getHostPlayer().id then
		local character = caller.character
		if character then
			if not _ then
				sm.storage.save("HOST_CHARACTER_RESTORE_POSITION", character.worldPosition)
			end
			character.worldPosition = sm.vec3.new(20000000, 20000000, 20000000)
		end
	end
end

function SurvivalGame.CHECK_ME(self, _, caller)
	if caller and caller.id == sm.player.getHostPlayer().id then
		self[g_excludeHostPlayer and "DESTROY_ME" or "RESTORE_ME"](true, caller)
	end
end

function SurvivalGame.RESTORE_ME(self, _, caller)
	if caller and caller.id == sm.player.getHostPlayer().id then
		local character = caller.character
		if character then
			local target = sm.storage.load("HOST_CHARACTER_RESTORE_POSITION")
			if target then
				character.worldPosition = target
			end
		end
	end
end

function SurvivalGame.sv_n_loadingScreenLifted( self, _, player )
	if not g_survivalDev then
		QuestManager.Sv_TryActivateQuest( "quest_tutorial" )
	end
end

function SurvivalGame.client_onLanguageChange( self, newLanguage )
	DialogManager.Cl_OnLanguageChange( newLanguage )
end

function SurvivalGame.client_onUnstuck( self )
	sm.event.sendToPlayer( sm.localPlayer.getPlayer(), "cl_e_unstuck" )
end

function SurvivalGame.sv_switchGodMode( self , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	g_godMode = not g_godMode
	self.network:sendToClients( "client_showMessage", "GODMODE: " .. ( g_godMode and "On" or "Off" ) )
end

function SurvivalGame.sv_n_switchAggroMode( self, params , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	sm.game.setEnableAggro(params.aggroMode )
	self.network:sendToClients( "client_showMessage", "AGGRO: " .. ( params.aggroMode and "On" or "Off" ) )
end

function SurvivalGame.sv_enableRestrictions( self, state , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	sm.game.setEnableRestrictions( state )
	self.network:sendToClients( "client_showMessage", ( state and "Restricted" or "Unrestricted"  ) )
end

function SurvivalGame.sv_setLimitedInventory( self, state , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	sm.game.setLimitedInventory( state )
	self.network:sendToClients( "client_showMessage", ( state and "Limited inventory" or "Unlimited inventory"  ) )
end

function SurvivalGame.sv_setTimeOfDay( self, timeOfDay , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	if timeOfDay then
		self.sv.time.timeOfDay = math.floor( self.sv.time.timeOfDay ) + sm.util.clamp( timeOfDay, 0.0, 0.9999 )
		self.sv.syncTimer.count = self.sv.syncTimer.ticks -- Force sync
	end
	self.network:sendToClients( "client_showMessage", ( "Time of day set to "..self.sv.time.timeOfDay ) )
end

function SurvivalGame.sv_setTimeProgress( self, timeProgress , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	if timeProgress ~= nil then
		self.sv.time.timeProgress = timeProgress
		self.sv.syncTimer.count = self.sv.syncTimer.ticks -- Force sync
	end
	self.network:sendToClients( "client_showMessage", ( "Time scale set to "..( self.sv.time.timeProgress and "on" or "off ") ) )
end

function SurvivalGame.sv_killPlayer( self, params , ... )
	if params == nil then
		return
	end
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) and not ( params ~= nil and params.player ~= nil and params.player.id == caller.id ) then
		return
	end
	params.damage = 9999
	params.source = "shock"
	sm.event.sendToPlayer( params.player, "sv_e_receiveDamage", params )
end

function SurvivalGame.sv_spawnUnit( self, params , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	sm.event.sendToWorld( params.world, "sv_e_spawnUnit", params )
end

function SurvivalGame.sv_spawnHarvestable( self, params , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	sm.event.sendToWorld( params.world, "sv_spawnHarvestable", params )
end

function SurvivalGame.sv_exportCreation( self, params , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	local obj = sm.json.parseJsonString( sm.creation.exportToString( params.body ) )
	sm.json.save( obj, "$SURVIVAL_DATA/LocalBlueprints/"..params.name..".blueprint" )
end

function SurvivalGame.sv_importCreation( self, params , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	sm.creation.importFromFile( params.world, "$SURVIVAL_DATA/LocalBlueprints/"..params.name..".blueprint", params.position )
end

function SurvivalGame.sv_smserverNotify( self, player, text )
	self.network:sendToClient( player, "cl_smserverMessage", text )
end

function SurvivalGame.cl_smserverMessage( self, text )
	sm.gui.chatMessage( text )
end

function SurvivalGame.cl_smserverOpenContainer( self, data )
	if type( data ) == "string" then
		sm.gui.chatMessage( data )
		return
	end
	local gui = sm.gui.createContainerGui( true )
	gui:setText( "UpperName", data.title or "" )
	gui:setContainer( "UpperGrid", data.container )
	gui:setText( "LowerName", "#{INVENTORY_TITLE}" )
	gui:setContainer( "LowerGrid", sm.localPlayer.getInventory() )
	gui:open()
end

function SurvivalGame.sv_teleport( self, data , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	if not data.player.character or not sm.exists( data.player.character ) then
		return
	end

	local world = data.world or self.sv.saved.overworld
	if not sm.exists( world ) then
		sm.world.loadWorld( world )
	end

	local cellX = math.floor( data.pos.x / 64 )
	local cellY = math.floor( data.pos.y / 64 )
	local dir = data.player.character:getDirection()
	world:loadCell( cellX, cellY, data.player, "sv_recreatePlayerCharacter", { pos = data.pos, dir = dir, world = data.world } )
end

function SurvivalGame.sv_smserverSpawnPart( self, uuid, position , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	if uuid == nil or position == nil or not sm.shape.uuidExists( uuid ) then
		return
	end
	if isBlockedShapeUuid( uuid ) then
		return
	end
	if not sm.exists( self.sv.saved.overworld ) then
		sm.world.loadWorld( self.sv.saved.overworld )
	end
	if not self.sv.smserverSpawner or not sm.exists( self.sv.smserverSpawner ) then
		self.sv.smserverSpawner = sm.scriptableObject.createScriptableObject( SmserverSpawnerUuid, nil, self.sv.saved.overworld )
	end
	sm.event.sendToScriptableObject( self.sv.smserverSpawner, "sv_e_spawnPart", { uuid = uuid, position = position, dynamic = true } )
end

function SurvivalGame.sv_smserverCommand( self, params, ... )
	-- Network-invoked handlers receive the true sender as the final argument.
	-- Never trust a player object coming from the payload.
	local player = smserver_getNetworkCaller( ... )
	if player == nil then
		return true
	end
	if params[1] == "/op" then
		if not smserver_isHost( player ) then
			self:sv_smserverNotify( player, "#ff0000only the host can manage administrators" )
			return true
		end
		
		local id = params[2]
		local target = servicetool.getPlayerById( id )
		if not target then
			self:sv_smserverNotify( player, "#ff0000no player with ID \"" .. tostring( id ) .. "\"" )
			return true
		end
		if smserver_isHost( target ) then
			self:sv_smserverNotify( player, "#ffAA00the host is always an administrator" )
			return true
		end

		local enable = params[3]
		if enable == nil then
			enable = true
		end
		if enable then
			self.sv.saved.smserver.admins[target.id] = true
		else
			self.sv.saved.smserver.admins[target.id] = nil
		end
		self.storage:save( self.sv.saved )
		self:sv_smserverNotify( player, enable and "#00ff00administrator rights granted" or "#ff00ffadministrator rights revoked" )
		return true
	elseif params[1] == "/ender" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return true
		end

		local data
		if not enderchest_user or not enderchest_public then
			self:sv_smserverNotify( player, "#ff0000place an ender chest first so its script is loaded" )
			return true
		end
		if params[2] then
			local target = servicetool.getPlayerByName( params[2] )
			if not target then
				self:sv_smserverNotify( player, "#ff0000no player named \"" .. tostring( params[2] ) .. "\"" )
				return true
			end
			data = enderchest_user( target.id, target.name )
			if not data then
				self:sv_smserverNotify( player, "#ff0000that player has no ender chest yet" )
				return true
			end
		else
			data = enderchest_public()
			if not data[2] then
				self:sv_smserverNotify( player, "#ff0000the public ender chest has not been created yet" )
				return true
			end
		end

		self.network:sendToClient( player, "cl_smserverOpenContainer", { title = data[1], container = data[2] } )
		return true
	elseif params[1] == "/tp" or params[1] == "/tpr" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return true
		end

		local target = servicetool.getPlayerByName( params[2] )
		if not target then
			self:sv_smserverNotify( player, "#ff0000no player named \"" .. tostring( params[2] ) .. "\"" )
			return true
		end
		if not target.character then
			self:sv_smserverNotify( player, "#ff0000that player has no character" )
			return true
		end
		if params[1] == "/tpr" and not player.character then
			self:sv_smserverNotify( player, "#ff0000you have no character" )
			return true
		end

		local mover, destination = player, target
		if params[1] == "/tpr" then
			mover, destination = target, player
		end
		self:sv_teleport( { player = mover, pos = destination.character.worldPosition + sm.vec3.new( 0, 0, 1.5 ), world = destination.character:getWorld() } )
		self:sv_smserverNotify( player, "#00ff00teleported" )
		return true
	elseif params[1] == "/tpp" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return true
		end
		if not ( params[2] and params[3] and params[4] ) then
			self:sv_smserverNotify( player, "#ff0000usage: /tpp <x> <y> <z>" )
			return true
		end
		if not smserver_isFinite( params[2] ) or not smserver_isFinite( params[3] ) or not smserver_isFinite( params[4] ) then
			self:sv_smserverNotify( player, "#ff0000coordinates must be finite numbers" )
			return true
		end
		if not player.character then
			self:sv_smserverNotify( player, "#ff0000you have no character" )
			return true
		end

		local pos = sm.vec3.new( params[2], params[3], params[4] )
		self:sv_teleport( { player = player, pos = pos, world = player.character:getWorld() } )
		self:sv_smserverNotify( player, "#00ff00teleported" )
		return true
	elseif params[1] == "/give" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return true
		end

		local ok, itemUuid = pcall( sm.uuid.new, params[2] )
		if not ok or not ( sm.shape.uuidExists( itemUuid ) or sm.tool.uuidExists( itemUuid ) ) then
			self:sv_smserverNotify( player, "#ff0000unknown item uuid \"" .. tostring( params[2] ) .. "\"" )
			return true
		end
		if isBlockedShapeUuid( itemUuid ) then
			self:sv_smserverNotify( player, "#ff0000this item is disabled" )
			return true
		end

		local quantity = smserver_clampInteger( params[3] or 1, 1, 1000 )
		self:sv_giveItem( { player = player, item = itemUuid, quantity = quantity } )
		self:sv_smserverNotify( player, "#00ff00item given" )
		return true
	elseif params[1] == "/spawnpart" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return true
		end

		local ok, partUuid = pcall( sm.uuid.new, params[2] )
		if not ok or not sm.shape.uuidExists( partUuid ) then
			self:sv_smserverNotify( player, '#ff0000unknown part uuid "' .. tostring( params[2] ) .. '"' )
			return true
		end
		if isBlockedShapeUuid( partUuid ) then
			self:sv_smserverNotify( player, "#ff0000this part is disabled" )
			return true
		end

		local character = player.character
		if not character then
			self:sv_smserverNotify( player, "#ff0000you have no character" )
			return true
		end
		local spawnPos = character.worldPosition + character:getDirection() * 4 + sm.vec3.new( 0, 0, 1 )
		self:sv_smserverSpawnPart( partUuid, spawnPos )
		self:sv_smserverNotify( player, "#00ff00part spawned" )
		return true
	elseif params[1] == "/unlimited" or params[1] == "/limited" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return true
		end
		self:sv_setLimitedInventory( params[1] == "/limited" )
		self:sv_smserverNotify( player, params[1] == "/limited" and "limited inventory" or "unlimited inventory" )
		return true
	elseif params[1] == "/ppos" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return true
		end
		local pos = player.character.worldPosition
		self:sv_smserverNotify( player, "x=" .. tostring( pos.x ) .. " y=" .. tostring( pos.y ) .. " z=" .. tostring( pos.z ) )
		return true
	end

	return false
end

function SurvivalGame.sv_onChatCommand( self, params, ... )
	local player = smserver_getNetworkCaller( ... )
	if player == nil then
		return
	end

	if self:sv_smserverCommand( params, player ) then
		return
	end

	-- The remaining branches are the stock debug/cheat commands. They are
	-- normally only bound in developer mode, but a modified client can invoke
	-- this handler directly, so gate them server-side.
	if not g_survivalDev and not smserver_isAdmin( player ) then
		return
	end

	if params[1] == "/kick" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return
		end
		if params[2] ~= nil then
			self:sv_kickPlayer( params[2] )
		end
	elseif params[1] == "/setHostExcluded" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return
		end
		
		-- Apply the flag to the running game as well, otherwise the command only
		-- changes what the next world load will read from storage.
		local new_state = params[2] == true
		if new_state == g_excludeHostPlayer then return end

		g_excludeHostPlayer = new_state
		sm.storage.saveAndSync( HOST_EXCLUDE_FLAG_STORAGE_KEY, g_excludeHostPlayer )
		self:sv_smserverNotify( player, "host exclusion " .. ( g_excludeHostPlayer and "enabled" or "disabled" ) )
		self:CHECK_ME(false, player)
	elseif params[1] == "/ban" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return
		end
		if params[2] ~= nil then
			self:sv_banPlayer( params[2] )
		end
	elseif params[1] == "/unban" then
		if not smserver_isAdmin( player ) then
			self:sv_smserverNotify( player, "#ff0000you are not an administrator" )
			return
		end
		if params[2] ~= nil then
			self:sv_unbanPlayer( params[2] )
		end
	elseif params[1] == "/tumble" then
		if params[2] ~= nil then
			player.character:setTumbling( params[2] )
		else
			player.character:setTumbling( not player.character:isTumbling() )
		end
		if player.character:isTumbling() then
			self.network:sendToClients( "client_showMessage", "Player is tumbling" )
		else
			self.network:sendToClients( "client_showMessage", "Player is not tumbling" )
		end
	elseif params[1] == "/sethp" then
		sm.event.sendToPlayer( player, "sv_e_debug", { hp = params[2] } )

	elseif params[1] == "/setbreath" then
		sm.event.sendToPlayer( player, "sv_e_debug", { breath = params[2] } )
	else
		params.player = player
		if sm.exists( player.character ) then
			sm.event.sendToWorld( player.character:getWorld(), "sv_e_onChatCommand", params )
		end
	end
end


function SurvivalGame.server_onPlayerJoined( self, player, newPlayer )
	--if player.id == get_host_player_chestno().id and g_excludeHostPlayer then
	--	if player.character ~= nil then
	--		player:setCharacter(nil)
	--	end
	--	return
	--end
	if self.sv.saved.banned_ids[player.id] then
		sm.game.kickPlayer(player)
		return
	end
	print( player.name, "joined the game" )
	self.sv.gotoLocations = self.sv.gotoLocations or {}
	self.sv.gotoLocations[#self.sv.gotoLocations+1] = string.lower( player.name )
	self.network:setClientData( { dev = g_survivalDev, gotoLocations = self.sv.gotoLocations }, 1 )
	WeatherManager.Sv_PlayerJoined( player )
	local inventory = player:getInventory()
	inventory:resize(g_PlayerInventoryMaxSlots)

	local spawnPoint = g_survivalDev and SURVIVAL_DEV_SPAWN_POINT or START_AREA_SPAWN_POINT
	if newPlayer then --Player joined for the first time
		--local inventory = player:getInventory()
		
		sm.container.beginTransaction()
		
		if g_survivalDev then
			if not sm.game.getLimitedInventory() then
				inventory = player:getHotbar()
			end
			--Hotbar
			sm.container.setItem( inventory, 0, ITEMS.tool_sledgehammer, 1 )
			sm.container.setItem( inventory, 1, ITEMS.tool_lift, 1 )
			sm.container.setItem( inventory, 2, ITEMS.tool_spudgun, 1 )
			sm.container.setItem( inventory, 3, ITEMS.obj_consumable_glowstick, 20 )
			sm.container.setItem( inventory, 9, ITEMS.tool_connect, 1 )

			--Actual inventory
			sm.container.setItem( inventory, 10, ITEMS.tool_paint, 1 )
			sm.container.setItem( inventory, 11, ITEMS.tool_weld, 1 )
		else
			sm.container.setItem( inventory, 0, ITEMS.tool_sledgehammer, 1 )
			sm.container.setItem( inventory, 1, ITEMS.tool_lift, 1 )
		end

		sm.container.endTransaction()

		if not sm.exists( self.sv.saved.overworld ) then
			sm.world.loadWorld( self.sv.saved.overworld )
		end
		self.sv.saved.overworld:loadCell( math.floor( spawnPoint.x/64 ), math.floor( spawnPoint.y/64 ), player, "sv_createNewPlayer" )
		self.network:sendToClient( player, "cl_n_onJoined", { newPlayer = newPlayer } )
	else
		--local inventory = player:getInventory()

		local sledgehammerCount = sm.container.totalQuantity( inventory, ITEMS.tool_sledgehammer )
		if sledgehammerCount == 0 then
			sm.container.beginTransaction()
			sm.container.collect( inventory, ITEMS.tool_sledgehammer, 1 )
			sm.container.endTransaction()
		elseif sledgehammerCount > 1 then
			sm.container.beginTransaction()
			sm.container.spend( inventory, ITEMS.tool_sledgehammer, sledgehammerCount - 1 )
			sm.container.endTransaction()
		end

		local tool_lift_creative = sm.uuid.new( "5cc12f03-275e-4c8e-b013-79fc0f913e1b" )
		local creativeLiftCount = sm.container.totalQuantity( inventory, tool_lift_creative )
		if creativeLiftCount > 0 then
			sm.container.beginTransaction()
			sm.container.spend( inventory, tool_lift_creative, creativeLiftCount )
			sm.container.endTransaction()
		end

		local liftCount = sm.container.totalQuantity( inventory, ITEMS.tool_lift )
		if liftCount == 0 then
			sm.container.beginTransaction()
			sm.container.collect( inventory, ITEMS.tool_lift, 1 )
			sm.container.endTransaction()
		elseif liftCount > 1 then
			sm.container.beginTransaction()
			sm.container.spend( inventory, ITEMS.tool_lift, liftCount - 1 )
			sm.container.endTransaction()
		end
		--if player.character == nil then
		--	self.sv.saved.overworld:loadCell( math.floor( spawnPoint.x/64 ), math.floor( spawnPoint.y/64 ), player, "sv_createNewPlayer" )
		--end
	end

	if player.id > 1 then --Too early for self. Questmanager is not created yet...
		QuestManager.Sv_SendEvent( QuestEvent.PlayerJoined, { player = player } )
	end
end

function SurvivalGame.server_onPlayerLeft( self, player )
	print( player.name, "left the game" )
	for i, name in ipairs( self.sv.gotoLocations ) do
		if name == string.lower( player.name ) then
			self.sv.gotoLocations[i] = nil
			break
		end
	end
	self.network:setClientData( { dev = g_survivalDev, gotoLocations = self.sv.gotoLocations }, 1 )
	if player.id > 1 then
		QuestManager.Sv_SendEvent( QuestEvent.PlayerLeft, { player = player } )
	end
	-- Dedicated-safe: there is no host player, and every leaver must be handled.
	local hostPlayer = sm.player.getHostPlayer()
	if hostPlayer == nil or player.id ~= hostPlayer.id then
		local carryInventory = player:getCarry()
		local currentCarry = carryInventory:getItem( 0 )
		if currentCarry and currentCarry.uuid ~= sm.uuid.getNil() then
			local character = player:getCharacter()
			if character and sm.exists( character ) then
				local world = character:getWorld()
				local subdivideRatio = 0.25
				local halfShapeSize = sm.item.getShapeSize( currentCarry.uuid ) * 0.5 * subdivideRatio
				local spawnPos = character:getWorldPosition() + sm.vec3.new( 0, 0, halfShapeSize.z + 1 )
				local shapePlacement = {
					worldPosition = spawnPos,
					worldRotation = sm.item.getShapeRotation( currentCarry.uuid ),
				}
				sm.event.sendToWorld( world, "sv_e_dropCarryShape",{
					itemA = currentCarry.uuid,
					characterShape = sm.item.getCharacterShape( currentCarry.uuid ),
					player = player,
					color = player:getCarryColor(),
					shapePlacement = shapePlacement,
					containerA = carryInventory,
					raycastNormal = sm.vec3.new( 0, 0, -1 ),
					aimPosition = spawnPos,
					quantityA = currentCarry.quantity
				},sm.event.types.instant )
			end
		end
	end
end

function SurvivalGame.sv_kickPlayer( self, name , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	local players = sm.player.getAllPlayers()

	for _, player in ipairs( players ) do
		if player:getName() == name then
			sm.game.kickPlayer( player )
		end
	end
end

function SurvivalGame.sv_banPlayer( self, name , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	local players = sm.player.getAllPlayers()

	for _, player in ipairs( players ) do
		if player:getName() == name then
			sm.game.banPlayer( player )
		end
	end
end
function SurvivalGame.sv_unbanPlayer( self, name , ... )
	local caller = smserver_getNetworkCaller( ... )
	if caller ~= nil and not smserver_isAdmin( caller ) then
		return
	end
	local players = sm.player.getAllPlayers()

	for _, player in ipairs( players ) do
		if player:getName() == name then
			sm.game.unbanPlayer( player )
		end
	end
end

-- 1.0.7 UndergroundElevatorManager creates the underground world itself (it no
-- longer asks a client-driven interactable to send the world here), so the old
-- sv_e_createUndergroundElevatorDestination handler was removed. The manager now
-- only reports the created world so the game script keeps its map and save in
-- sync.
function SurvivalGame.sv_e_addUndergroundWorld( self, params , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	if type( params ) ~= "table" or params.depth == nil or params.world == nil then
		return
	end
	self.sv.undergroundWorlds[params.depth] = params.world
	sm.storage.save( STORAGE_CHANNEL_UNDERGROUND_WORLDS, self.sv.undergroundWorlds )
end


function SurvivalGame.sv_createNewPlayer( self, world, x, y, player )
	local params = { player = player, x = x, y = y }
	sm.event.sendToWorld( self.sv.saved.overworld, "sv_spawnNewCharacter", params )
end

function SurvivalGame.sv_spawnEjectedPlayer( self, world, x, y, player )
	local cellPosition = sm.vec3.new( x * 64.0, y * 64.0, 0 )
	local fallbackPosition = cellPosition + sm.vec3.one() * 32.0

	local yaw = 0
	local pitch = 0
	local spawnPosition = nil

	local findEjectNode = function()
		local xMin,xMax,yMin,yMax = GetTileRangesFromCell( x, y, world.id )
		for xit = xMin, xMax, 1 do
			for yit = yMin, yMax, 1 do
				local nodes = sm.cell.getNodesByTag( xit, yit, "WAREHOUSE_EJECT", world )
				if #nodes > 0 then
					local spawnerIndex = ( ( player.id - 1 ) % #nodes ) + 1 -- distribute players over multiple nodes
					local spawnNode = nodes[spawnerIndex]
					local spawnPosition = spawnNode.position + sm.vec3.new( 0, 0, 0.7 )
			
					local spawnDirection = spawnNode.rotation * sm.vec3.new( 0, 0, 1 )
					local spawnYaw = math.atan2( spawnDirection.y, spawnDirection.x ) - math.pi/2
					return spawnPosition, spawnYaw
				end
			end
		end
		return fallbackPosition, yaw
	end
	spawnPosition, yaw = findEjectNode()

	local character = sm.character.createCharacter( player, world, spawnPosition, yaw, pitch )
	player:setCharacter( character )
	character:setTumbling( true )
end

function SurvivalGame.sv_recreatePlayerCharacter( self, world, x, y, player, params )
	local yaw = math.atan2( params.dir.y, params.dir.x ) - math.pi/2
	local pitch = math.asin( params.dir.z )
	local newCharacter
	local pos = params.pos










	if params.world then
		newCharacter = sm.character.createCharacter( player, params.world, pos, yaw, pitch )
	else
		newCharacter = sm.character.createCharacter( player, self.sv.saved.overworld, pos, yaw, pitch )
	end
	player:setCharacter( newCharacter )
	if params.fadeFromBlack then
		sm.event.sendToPlayer( player, "sv_endFadeToBlack", { duration = 2.0, force = true }, sm.event.types.instant )
	end
	print( "Recreate character in new world" )
	print( params )
end











function SurvivalGame.sv_e_recreatePlayerInWorld( self, params , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	local world = params.world
	if not sm.exists( world ) then
		sm.world.loadWorld( world )

	end
	local cellX = math.floor( params.pos.x / 64 )
	local cellY = math.floor( params.pos.y / 64 )
	
	if params.fadeFromBlack then
		sm.event.sendToPlayer( params.player, "sv_endFadeToBlack", { duration = 2.0, force = true }, sm.event.types.instant )
	end

	world:loadCell( cellX, cellY, params.player, "sv_recreatePlayerCharacter", { pos = params.pos, dir = params.dir, world = world } )
end

function SurvivalGame.sv_e_respawn( self, params , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	if params.player.character and sm.exists( params.player.character ) then
		g_respawnManager:sv_requestRespawnCharacter( params.player )
	else
		local spawnPoint = g_survivalDev and SURVIVAL_DEV_SPAWN_POINT or START_AREA_SPAWN_POINT
		if not sm.exists( self.sv.saved.overworld ) then
			sm.world.loadWorld( self.sv.saved.overworld )
		end
		self.sv.saved.overworld:loadCell( math.floor( spawnPoint.x/64 ), math.floor( spawnPoint.y/64 ), params.player, "sv_createNewPlayer" )
	end
end

function SurvivalGame.sv_e_warehouseEject( self, params , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	local warehouse = WarehouseManager.Sv_GetWarehouseFromIndex( params.warehouseIndex )
	local spawnCoords
	if warehouse and warehouse.exits and warehouse.exits[1] then
		spawnCoords = warehouse.exits[1]
	else
		sm.log.error( "Failed to find an exit to eject from, for warehouse: ", params.warehouseIndex )
		local spawnPoint = g_survivalDev and SURVIVAL_DEV_SPAWN_POINT or START_AREA_SPAWN_POINT
		spawnCoords = { x = math.floor( spawnPoint.x / 64.0 ), y = math.floor( spawnPoint.y / 64.0 ) }
	end
	if not sm.exists( self.sv.saved.overworld ) then
		sm.world.loadWorld( self.sv.saved.overworld )
	end
	self.sv.saved.overworld:loadCell( spawnCoords.x, spawnCoords.y, params.player, "sv_spawnEjectedPlayer" )
end

function SurvivalGame.sv_loadedRespawnCell( self, world, x, y, player )
	g_respawnManager:sv_respawnCharacter( player, world )
end

function SurvivalGame.sv_e_onSpawnPlayerCharacter( self, player , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	if player.character and sm.exists( player.character ) then
		g_respawnManager:sv_onSpawnCharacter( player )
		g_beaconManager:sv_onSpawnCharacter( player )
	else
		sm.log.warning("SurvivalGame.sv_e_onSpawnPlayerCharacter for a character that doesn't exist")
	end
end

function SurvivalGame.sv_e_markBag( self, params , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	self.network:sendToClient( params.player, "cl_n_markBag", params.bags )
end

function SurvivalGame.cl_n_markBag( self, params )
	g_respawnManager:cl_markBag( params )
end

function SurvivalGame.sv_e_unmarkBag( self, player , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	self.network:sendToClient( player, "cl_n_unmarkBag" )
end

function SurvivalGame.cl_n_unmarkBag( self )
	g_respawnManager:cl_unmarkBag()
end

function SurvivalGame.sv_e_removeBag( self, params , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	self.network:sendToClient( params.player, "cl_e_removeBag", params.bags )
end

function SurvivalGame.cl_e_removeBag( self, params )
	g_respawnManager:cl_removeBag( params )
end

-- Beacons
function SurvivalGame.sv_e_createBeacon( self, params , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	if sm.exists( params.beacon.world ) then
		sm.event.sendToWorld( params.beacon.world, "sv_e_createBeacon", params )
	else
		sm.log.warning( "SurvivalGame.sv_e_createBeacon in a world that doesn't exist" )
	end
end

function SurvivalGame.sv_e_destroyBeacon( self, params , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	if sm.exists( params.beacon.world ) then
		sm.event.sendToWorld( params.beacon.world, "sv_e_destroyBeacon", params )
	else
		sm.log.warning( "SurvivalGame.sv_e_destroyBeacon in a world that doesn't exist" )
	end
end

function SurvivalGame.sv_e_unloadBeacon( self, params , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	if sm.exists( params.beacon.world ) then
		sm.event.sendToWorld( params.beacon.world, "sv_e_unloadBeacon", params )
	else
		sm.log.warning( "SurvivalGame.sv_e_unloadBeacon in a world that doesn't exist" )
	end
end

function SurvivalGame.cl_e_overworldCreated( self, world )
	self.cl.overworld = world
end









































































































































































function SurvivalGame.sv_e_grantAdditionalRewards( self, rewardList , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	self.network:sendToClients( "cl_n_grantAdditionalRewards", rewardList )
end

function SurvivalGame.sv_e_grantAdditionalRewardsForPlayer( self, args  , ... )
	if smserver_getNetworkCaller( ... ) ~= nil then
		return
	end
	self.network:sendToClient( args.player, "cl_n_grantAdditionalRewards", args.rewardList )
end

function SurvivalGame.cl_n_grantAdditionalRewards( self, rewardList )
	Cl_GrantAdditionalItems( rewardList )
end
