dofile( "$CONTENT_DATA/Scripts/util.lua" )

ElevatorManager = class( nil )

local ELEVATOR_TRAVEL_TICKS = 680
local ELEVATOR_MOVEWALLS_TICK = ELEVATOR_TRAVEL_TICKS - 60
local ELEVATOR_LOAD_WORLDS_TICK = ELEVATOR_MOVEWALLS_TICK - 60
local ELEVATOR_TRANSFER_TICK = 120
local ELEVATOR_START_FADE = ELEVATOR_TRANSFER_TICK + 40 -- Sometime before transfer
local ELEVATOR_END_FADE = 40 -- Before doors open
 
local ELEVATOR_FADE_TIMEOUT = ELEVATOR_START_FADE * ( 1.0 / 40.0 ) + 5.0
local ELEVATOR_FADE_DURATION = 0.45

function ElevatorManager.server_onCreate( self )
	g_elevatorManager = self


	-- Game script managed global elevator table
	self.elevators = sm.storage.load( STORAGE_CHANNEL_ELEVATORS )
	if not self.elevators then
		self.elevators = {}
		self:sv_saveElevators()
	end

	self.activeElevators = {}
	self.objectToElevator = {}

	self.loadedCells = {}
	self.loadHandles = {}
end


function ElevatorManager.sv_loadElevatorsOnOverworldCell( self, x, y, cellTags )

	local exits = {}
	local nodes = sm.cell.getNodesByTag( x, y, "ELEVATOR_EXIT_HINT" )
	for i = 1, #nodes do
		local node = nodes[ i ]
		local vector = node.rotation * ( sm.vec3.new( 0, 1, 0 ) * node.scale )
		local cellX, cellY = getCell( node.position.x + vector.x, node.position.y + vector.y )
		exits[ i ] = { x = cellX, y = cellY }
	end

	-- Cell-wide values; computed once instead of once per elevator.
	local maxLevels = 0
	local foundFloorTag = false
	local foundTestTag = false
	for i = 1, #cellTags do
		local tag = cellTags[ i ]
		local floors = CELL_TAG_TO_WAREHOUSE_FLOORS[ tag ]
		if floors then
			maxLevels = floors
			foundFloorTag = true
			foundTestTag = tag == "POI_TEST"
			break
		end
	end
	if not foundFloorTag then
		maxLevels = 4
	end

	local elevators = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR", "ENTRANCE" } )
	if #exits == 0 and #elevators > 0 then
		sm.log.error( "Elevator on ("..x..", "..y..") does not have an exit hint" )
	end
	for i = 1, #elevators do
		elevators[ i ]:setParams( {
			name = "ELEVATOR_ENTRANCE",
			x = x,
			y = y,
			exits = exits,
			maxLevels = maxLevels,
			test = foundTestTag,
			cellTags = cellTags
		} )
	end

	elevators = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR", "EXIT" } )
	for i = 1, #elevators do
		elevators[ i ]:setParams( {
			name = "ELEVATOR_EXIT",
			x = x,
			y = y,
			maxLevels = maxLevels,
			test = foundTestTag,
			cellTags = cellTags
		} )
	end

	local buttons = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR_BUTTON", "ENTRANCE" } )
	for i = 1, #buttons do
		buttons[ i ]:setParams( { goingUp = true } )
	end

	buttons = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR_BUTTON", "EXIT" } )
	for i = 1, #buttons do
		buttons[ i ]:setParams( { goingUp = false } )
	end
end

function ElevatorManager.sv_loadElevatorsOnWarehouseCell( self, x, y, warehouseIndex, level )
	local elevators = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR", "ENTRANCE" } )
	for i = 1, #elevators do
		elevators[ i ]:setParams( {
			name = "ELEVATOR_ENTRANCE",
			warehouseIndex = warehouseIndex,
			level = level
		} )
	end

	elevators = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR", "UP" } )
	for i = 1, #elevators do
		elevators[ i ]:setParams( {
			name = "ELEVATOR_UP",
			warehouseIndex = warehouseIndex,
			level = level
		} )
	end

	elevators = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR", "DOWN" } )
	for i = 1, #elevators do
		elevators[ i ]:setParams( {
			name = "ELEVATOR_DOWN",
			warehouseIndex = warehouseIndex,
			level = level
		} )
	end

	elevators = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR", "EXIT" } )
	for i = 1, #elevators do
		elevators[ i ]:setParams( {
			name = "ELEVATOR_EXIT",
			warehouseIndex = warehouseIndex,
			level = level
		} )
	end

	local buttons = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR_BUTTON", "ENTRANCE" } )
	for i = 1, #buttons do
		buttons[ i ]:setParams( { goingUp = false } )
	end

	buttons = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR_BUTTON", "UP" } )
	for i = 1, #buttons do
		buttons[ i ]:setParams( { goingUp = true } )
	end

	buttons = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR_BUTTON", "DOWN" } )
	for i = 1, #buttons do
		buttons[ i ]:setParams( { goingUp = false } )
	end

	buttons = sm.cell.getInteractablesByTags( x, y, { "ELEVATOR_BUTTON", "EXIT" } )
	for i = 1, #buttons do
		buttons[ i ]:setParams( { goingUp = true } )
	end
end

function ElevatorManager.sv_saveElevators( self )
	sm.storage.save( STORAGE_CHANNEL_ELEVATORS, self.elevators )
end

local function CellKey( world, x, y )
	return world.id..":("..x..","..y..")"
end

-- Loads the 3x3 cell block around a cell coordinate and returns the load handles.
local function LoadCellsAroundCell( world, x, y )
	local handles = {}
	local count = 0
	for cellX = x - 1, x + 1 do
		for cellY = y - 1, y + 1 do
			if world:isCellInBounds( cellX, cellY ) then
				local handle = world:loadCellWithHandle( cellX, cellY, nil )
				if handle ~= nil then
					count = count + 1
					handles[ count ] = handle
				end
			end
		end
	end
	return handles
end

-- Determines which portal opening an interactable belongs to.
-- World comparison works after reloads; missing openings cover the creation flow
-- (the creator registers before setting opening A, the finder before setting opening B).
local function GetElevatorSide( portal, interactable )
	local body = interactable.body
	local world = body and body:getWorld()
	if world ~= nil then
		local worldId = world.id
		local worldA = portal:getWorldA()
		if worldA and sm.exists( worldA ) and worldA.id == worldId then
			return "a"
		end
		local worldB = portal:getWorldB()
		if worldB and sm.exists( worldB ) and worldB.id == worldId then
			return "b"
		end
	end

	if not portal:hasOpeningA() then
		return "a"
	end
	if not portal:hasOpeningB() then
		return "b"
	end
	return nil
end

function ElevatorManager.sv_onCellLoaded( self, world, x, y )
	self.loadedCells[CellKey( world, x, y )] = true
end

function ElevatorManager.sv_onCellUnloaded( self, world, x, y )
	self.loadedCells[CellKey( world, x, y )] = nil
end

function ElevatorManager.server_onFixedUpdate( self )
	local save = false
	local elevators = self.activeElevators

	for i = 1, #elevators do
		local elevator = elevators[ i ]

		-- Transfer
		if elevator.ticksToDestination == ELEVATOR_TRANSFER_TICK then
			if self:sv_isElevatorReadyForTransfer( elevator ) then
				if elevator.destination == "b" then
					elevator.portal:transferAToB()
				else--if elevator.destination == "a" then
					elevator.portal:transferBToA()
				end
			else
				sm.log.info( "An elevator wants to transfer to '"..elevator.destination.."' but destination is not ready, added 1 second" )
				elevator.ticksToDestination = ELEVATOR_TRANSFER_TICK + 40

				local portal = elevator.portal
				if self:sv_needToLoadWorlds( portal ) then
					self:sv_loadPortalWorlds( portal )
				end

				self:sv_prepareCells( portal )
			end
			save = true
		end

		local ticks = elevator.ticksToDestination

		if ticks == 0 then
			-- Open doors, but only when the applied state differs from the destination.
			local destination = elevator.destination
			if elevator.doorSide ~= destination then
				local doorA = elevator.a
				if doorA and sm.exists( doorA ) then
					doorA.active = destination == "a"
					doorA:setPower( 0 )
				end
				local doorB = elevator.b
				if doorB and sm.exists( doorB ) then
					doorB.active = destination == "b"
					doorB:setPower( 0 )
				end
				elevator.doorSide = destination
			end
		elseif ticks > 0 then -- Elevator is moving

			-- Countdown
			ticks = ticks - 1
			elevator.ticksToDestination = ticks
			if ticks == 0 then
				save = true
				self:sv_arrived( elevator )
			end

			-- Close doors once per travel and move the walls at the exit section.
			local closeDoors = elevator.doorSide ~= nil
			if closeDoors or ticks == ELEVATOR_MOVEWALLS_TICK then
				local destination = elevator.destination

				local doorA = elevator.a
				if doorA and sm.exists( doorA ) then
					if closeDoors then
						doorA.active = false
					end
					if ticks == ELEVATOR_MOVEWALLS_TICK then
						doorA:setPower( destination == "a" and -1 or 1 )
					end
				end

				local doorB = elevator.b
				if doorB and sm.exists( doorB ) then
					if closeDoors then
						doorB.active = false
					end
					if ticks == ELEVATOR_MOVEWALLS_TICK then
						doorB:setPower( destination == "b" and 1 or -1 )
					end
				end

				if closeDoors then
					elevator.doorSide = nil
				end
			end

			local portal = elevator.portal

			-- Start Fade
			if ticks == ELEVATOR_START_FADE then
				local destination = elevator.destination
				if destination == "b" then
					if portal:getWorldB() then
						self:sv_sendFadeToBlackEvent( portal:getContentsA(), true )
					end
				elseif destination == "a" then
					if portal:getWorldA() then
						self:sv_sendFadeToBlackEvent( portal:getContentsB(), true )
					end
				end
			end

			if ticks == ELEVATOR_LOAD_WORLDS_TICK then
				self:sv_loadPortalWorlds( portal )
			end

			-- Prepare for transfer
			if ticks < ELEVATOR_LOAD_WORLDS_TICK and
			   ticks > ELEVATOR_TRANSFER_TICK
			then
				local handles = self.loadHandles[ portal.id ]
				if handles == nil or handles.a == nil or handles.b == nil then
					self:sv_prepareCells( portal )
				end
			end

			-- End Fade
			if ticks == ELEVATOR_END_FADE then
				local destination = elevator.destination
				if destination == "a" then
					if portal:getWorldB() then
						self:sv_sendFadeToBlackEvent( portal:getContentsA(), false )
					end
				elseif destination == "b" then
					if portal:getWorldA() then
						self:sv_sendFadeToBlackEvent( portal:getContentsB(), false )
					end
				end
			end
		end
	end

	if save then
		self:sv_saveElevators()
	end
end

function ElevatorManager.sv_loadBForPlayersInElevator( self, portalId, world, x, y )
	local handles = self.loadHandles[ portalId ]
	if handles == nil then
		handles = {}
		self.loadHandles[ portalId ] = handles
	end

	if handles.b ~= nil then
		return
	end

	if world == nil or not sm.exists( world ) then
		return
	end

	handles.b = LoadCellsAroundCell( world, x, y )
end

function ElevatorManager.sv_sendFadeToBlackEvent( self, contents, start )
	if contents == nil then
		return
	end

	local eventName, params
	if start then
		eventName = "sv_startFadeToBlack"
		params = { duration = ELEVATOR_FADE_DURATION, timeout = ELEVATOR_FADE_TIMEOUT }
	else
		eventName = "sv_endFadeToBlack"
		params = { duration = ELEVATOR_FADE_DURATION }
	end

	for i = 1, #contents do
		local object = contents[ i ]
		if type( object ) == "Character" and sm.exists( object ) then
			local player = object:getPlayer()
			if player then
				sm.event.sendToPlayer( player, eventName, params )
			end
		end
	end
end

function ElevatorManager.sv_prepareCells( self, portal )
	local handles = self.loadHandles[ portal.id ]
	if handles ~= nil and handles.a ~= nil and handles.b ~= nil then
		return
	end
	if handles == nil then
		handles = {}
		self.loadHandles[ portal.id ] = handles
	end

	if handles.a == nil then
		local world = portal:getWorldA()
		if world and sm.exists( world ) then
			local position = portal:getPositionA()
			if position then
				local x, y = getCell( position.x, position.y )
				handles.a = LoadCellsAroundCell( world, x, y )
			end
		end
	end

	if handles.b == nil then
		local world = portal:getWorldB()
		if world and sm.exists( world ) then
			local position = portal:getPositionB()
			if position then
				local x, y = getCell( position.x, position.y )
				handles.b = LoadCellsAroundCell( world, x, y )
			end
		end
	end
end

-- Shape context

function ElevatorManager.sv_registerElevator( self, interactable, portal )
	local elevator = self.elevators[ portal.id ]
	local changed = false

	if elevator == nil then
		-- Does not exist, create it with the interactable on its resolved side.
		elevator = {
			portal = portal,
			destination = "b",
			ticksToDestination = 0, -- At destination
		}
		if GetElevatorSide( portal, interactable ) == "b" then
			elevator.b = interactable
		else
			elevator.a = interactable
		end
		self.elevators[ portal.id ] = elevator
		changed = true
	elseif elevator.a ~= interactable and elevator.b ~= interactable then
		-- Exists, bind the interactable to its own portal side (or to a stale slot).
		local side = GetElevatorSide( portal, interactable )
		if side == "a" then
			if elevator.a == nil or not sm.exists( elevator.a ) then
				elevator.a = interactable
				changed = true
			else
				sm.log.error( "ElevatorManager: duplicate A-side interactable registered for one portal" )
			end
		elseif side == "b" then
			if elevator.b == nil or not sm.exists( elevator.b ) then
				elevator.b = interactable
				changed = true
			else
				sm.log.error( "ElevatorManager: duplicate B-side interactable registered for one portal" )
			end
		elseif elevator.a == nil or not sm.exists( elevator.a ) then
			elevator.a = interactable
			changed = true
		elseif elevator.b == nil or not sm.exists( elevator.b ) then
			elevator.b = interactable
			changed = true
		else
			sm.log.error( "ElevatorManager: more than two interactables registered for one portal" )
		end
	end

	-- Any (re)created interactable starts with closed doors; let the fixed update re-apply the state.
	elevator.doorSide = nil

	if elevator.portal ~= portal then
		elevator.portal = portal
		changed = true
	end

	if changed then
		self:sv_saveElevators()
	end

	addToArrayIfNotExists( self.activeElevators, elevator )
	self.objectToElevator[ interactable.id ] = elevator
end


function ElevatorManager.sv_removeElevator( self, interactable )
	local elevator = self.objectToElevator[ interactable.id ]
	if elevator == nil then
		return
	end

	self.objectToElevator[ interactable.id ] = nil

	local stillMapped = false
	for _, e in pairs( self.objectToElevator ) do
		if e == elevator then
			stillMapped = true
			break
		end
	end

	if not stillMapped then
		local active = self.activeElevators
		for i = 1, #active do
			if active[ i ] == elevator then
				active[ i ] = active[ #active ]
				active[ #active ] = nil
				break
			end
		end
	end
end

function ElevatorManager.sv_getElevatorDestination( self, interactable )
	local elevator = self.objectToElevator[ interactable.id ]
	if elevator == nil then
		return nil
	end

	return elevator.destination, elevator.ticksToDestination
end

function ElevatorManager.sv_getElevatorHome( self, interactable )
	local elevator = self.objectToElevator[ interactable.id ]
	if elevator == nil then
		return nil
	end

	if interactable == elevator.b then
		return "b"
	end
	return "a"
end

function ElevatorManager.sv_call( self, interactable )
	local elevator = self.objectToElevator[ interactable.id ]
	if elevator == nil or elevator.ticksToDestination ~= 0 then -- Not on the move
		return
	end

	if elevator.destination == "b" and interactable == elevator.a then
		elevator.destination = "a"
		elevator.ticksToDestination = ELEVATOR_TRAVEL_TICKS
	elseif elevator.destination == "a" and interactable == elevator.b then
		elevator.destination = "b"
		elevator.ticksToDestination = ELEVATOR_TRAVEL_TICKS
	end
end


function ElevatorManager.sv_go( self, interactable )
	local elevator = self.objectToElevator[ interactable.id ]
	if elevator == nil or elevator.ticksToDestination ~= 0 then -- Not on the move
		return
	end

	if elevator.destination == "a" and interactable == elevator.a then
		-- A to B
		elevator.destination = "b"
		elevator.ticksToDestination = ELEVATOR_TRAVEL_TICKS

	elseif elevator.destination == "b" and interactable == elevator.b then
		-- B to A
		elevator.destination = "a"
		elevator.ticksToDestination = ELEVATOR_TRAVEL_TICKS
	elseif interactable == elevator.a then
		elevator.destination = "b"
		elevator.ticksToDestination = ELEVATOR_TRANSFER_TICK + 40
		elevator.a:setPower( 1 )
	elseif interactable == elevator.b then
		elevator.destination = "a"
		elevator.ticksToDestination = ELEVATOR_TRANSFER_TICK + 40
		elevator.b:setPower( -1 )
	end
end

function ElevatorManager.sv_arrived( self, elevator )
	local portalId = elevator.portal.id
	local handles = self.loadHandles[ portalId ]
	if handles == nil then
		return
	end

	local list = handles.a
	if list ~= nil then
		for i = 1, #list do
			list[ i ]:release()
		end
		handles.a = nil
	end

	list = handles.b
	if list ~= nil then
		for i = 1, #list do
			list[ i ]:release()
		end
		handles.b = nil
	end

	self.loadHandles[ portalId ] = nil
end


function ElevatorManager.sv_isElevatorReadyForTransfer( self, elevator )
	local portal = elevator.portal
	local world, position
	if elevator.destination == "a" then
		world = portal:getWorldA()
		position = portal:getPositionA()
	else
		world = portal:getWorldB()
		position = portal:getPositionB()
	end

	if world == nil or position == nil or not sm.exists( world ) then
		return false
	end

	local x = math.floor( position.x / 64 )
	local y = math.floor( position.y / 64 )
	return self.loadedCells[ CellKey( world, x, y ) ] == true
end

function ElevatorManager.sv_needToLoadWorlds( self, portal )
	local worldA, worldB = portal:getWorldA(), portal:getWorldB()
	if worldA and not sm.exists( worldA ) then
		return true
	end
	if worldB and not sm.exists( worldB ) then
		return true
	end
	return false
end

function ElevatorManager.sv_loadPortalWorlds( self, portal )
	local worldA = portal:getWorldA()
	if worldA and not sm.exists( worldA ) then
		sm.world.loadWorld( worldA )
	end

	local worldB = portal:getWorldB()
	if worldB and not sm.exists( worldB ) then
		sm.world.loadWorld( worldB )
	end
end

function ElevatorManager.Sv_CreateElevatorDestination( params )
	if g_elevatorManager then
		sm.event.sendToScriptableObject( g_elevatorManager.scriptableObject, "sv_e_createElevatorDestination", params, sm.event.types.instant )
	end
end

function ElevatorManager.sv_e_createElevatorDestination( self, params )
	local portal = params.portal
	if portal == nil then
		sm.log.error( "ElevatorManager: elevator destination requested without a portal" )
		return
	end

	-- Warehouse get or create
	local warehouse
	if params.warehouseIndex then
		warehouse = WarehouseManager.Sv_GetWarehouseFromIndex( params.warehouseIndex )
	else
		if params.name ~= "ELEVATOR_ENTRANCE" then
			sm.log.error( "ElevatorManager: no warehouse to create a destination for '"..tostring( params.name ).."'" )
			return
		end
		warehouse = WarehouseManager.Sv_CreateWarehouse( {
			world = portal:getWorldA(),
			position = params.position,
			maxLevels = params.maxLevels,
			exits = params.exits,
			cellTags = params.cellTags,
			test = params.test,
		} )
	end

	if warehouse == nil then
		sm.log.error( "ElevatorManager: warehouse "..tostring( params.warehouseIndex ).." not found" )
		return
	end

	-- Level up
	local level
	if params.level then
		if params.name == "ELEVATOR_UP" then
			level = params.level + 1
		elseif params.name == "ELEVATOR_DOWN" then
			level = params.level - 1
		elseif params.name == "ELEVATOR_EXIT" then
			if #warehouse.exits > 0 then
				if not sm.exists( warehouse.world ) then
					sm.world.loadWorld( warehouse.world )
				end
				for i = 1, #warehouse.exits do
					local cell = warehouse.exits[ i ]
					local name = params.name.." "..cell.x..","..cell.y
					sm.portal.addWorldPortalHook( warehouse.world, name, portal )
					ElevatorManager.Sv_LoadBForPlayersInElevator( portal.id, warehouse.world, cell.x, cell.y )
				end
			else
				sm.log.error( "No exit hint found, this elevator is going nowhere!" )
			end
			return
		else
			sm.log.error( "ElevatorManager: invalid elevator destination name '"..tostring( params.name ).."'" )
			return
		end
	else
		if params.name == "ELEVATOR_EXIT" then
			level = warehouse.maxLevels
		elseif params.name == "ELEVATOR_ENTRANCE" then
			level = 1
		else
			sm.log.error( "ElevatorManager: invalid elevator name '"..tostring( params.name ).."'" )
			return
		end
	end

	-- Create warehouse world
	local worldData = {
		level = level,
		isQuestWarehouse = warehouse.isQuestWarehouse,
		warehouseIndex = warehouse.index,
		maxLevels = warehouse.maxLevels,
	}

	local world = sm.world.createWorld( "$CONTENT_DATA/Scripts/game/worlds/WarehouseWorld.lua", "WarehouseWorld", worldData, math.random( 1073741823 ) )
	warehouse.worlds[#warehouse.worlds+1] = world
	WarehouseManager.Sv_SaveAndSynch()

	-- Elevator portal hook
	local name
	if params.name == "ELEVATOR_UP" then
		name = "ELEVATOR_DOWN"
	elseif params.name == "ELEVATOR_DOWN" then
		name = "ELEVATOR_UP"
	else
		name = params.name
	end
	sm.portal.addWorldPortalHook( world, name, portal )
	ElevatorManager.Sv_LoadBForPlayersInElevator( portal.id, world, 0, 0 )
end

function ElevatorManager.Sv_OnCellLoaded( world, x, y )
	if g_elevatorManager then
		g_elevatorManager:sv_onCellLoaded( world, x, y )
	end
end

function ElevatorManager.Sv_OnCellUnloaded( world, x, y )
	if g_elevatorManager then
		g_elevatorManager:sv_onCellUnloaded( world, x, y )
	end
end

function ElevatorManager.Sv_Go( object )
	if g_elevatorManager then
		g_elevatorManager:sv_go( object )
	end
end

function ElevatorManager.Sv_Call( object )
	if g_elevatorManager then
		g_elevatorManager:sv_call( object )
	end
end

function ElevatorManager.Sv_RegisterElevator( object, portal )
	if g_elevatorManager then
		g_elevatorManager:sv_registerElevator( object, portal )
	end
end

function ElevatorManager.Sv_RemoveElevator( object )
	if g_elevatorManager then
		g_elevatorManager:sv_removeElevator( object )
	end
end

function ElevatorManager.Sv_GetElevatorHome( object )
	if g_elevatorManager then
		return g_elevatorManager:sv_getElevatorHome( object )
	end
end

function ElevatorManager.Sv_GetElevatorDestination( object )
	if g_elevatorManager then
		return g_elevatorManager:sv_getElevatorDestination( object )
	end
end

function ElevatorManager.Sv_LoadBForPlayersInElevator( portalId, world, x, y )
	if g_elevatorManager then
		g_elevatorManager:sv_loadBForPlayersInElevator( portalId, world, x, y )
	end
end

function ElevatorManager.Sv_LoadElevatorsOnOverworldCell( x, y, cellTags )
	if g_elevatorManager then
		g_elevatorManager:sv_loadElevatorsOnOverworldCell( x, y, cellTags )
	end
end

function ElevatorManager.Sv_LoadElevatorsOnWarehouseCell( x, y, warehouseIndex, level )
	if g_elevatorManager then
		g_elevatorManager:sv_loadElevatorsOnWarehouseCell( x, y, warehouseIndex, level )
	end
end

