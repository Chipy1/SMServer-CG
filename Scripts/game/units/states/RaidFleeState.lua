dofile( "$CONTENT_DATA/Scripts/game/units/states/BaseState.lua" )

-- A raider whose raid is over paths back to the position it spawned at, which has a known route out of the player's base.
-- It keeps pathing while it is inside the circle around the raid center that reaches nearly to its spawn position, then runs straight away from the raid center.
-- Without a known center or spawn position it runs away right away.
RaidFleeState = class( BaseState )

local FleeCircleMargin = 5.0 -- the circle ends this far before the spawn position

-- pathingState: a PathingState that can reach the spawn position; fleeState: a state that runs away from self.fleeFrom
function RaidFleeState.sv_onCreate( self, unit, pathingState, fleeState )
	self.unit = unit
	self.pathingState = pathingState
	self.fleeState = fleeState
	self.currentState = fleeState
end

function RaidFleeState.sv_setRaid( self, raidKey )
	self.raidKey = raidKey
end

-- A swimmer flees through water instead of avoiding it
function RaidFleeState.sv_setSwims( self, swims )
	self.swims = swims
	self.pathingState:sv_setWaterAvoidance( not swims )
	self.fleeState.waterAvoidance = not swims
end

function RaidFleeState.start( self )
	self.started = true
	self.openFlee = false
	self.fleeRadius = nil

	local worldId = self.unit.character:getWorld().id
	local center = RaidManager.Sv_GetRaidCenter( worldId, self.raidKey )
	local spawnPosition = RaidManager.Sv_GetRaiderSpawnPosition( worldId, self.raidKey, self.unit )
	self.center = center
	-- Without a fleeing raid record (saves from before it existed, or an expired record) this is a plain flee from the center, or from the closest player if the center is unknown
	self.fleeState.fleeFrom = center -- nil flees from the closest player

	if center and spawnPosition then
		local toSpawn = spawnPosition - center
		toSpawn.z = 0
		self.fleeRadius = math.max( toSpawn:length() - FleeCircleMargin, 0 )
		self.pathDestination = spawnPosition + sm.vec3.new( 0, 0, self.unit.character:getHeight() * 0.5 )
	end

	if self.fleeRadius and not self:isOutsideFleeCircle() then
		self.pathingState:sv_setDestination( self.pathDestination )
		self.currentState = self.pathingState
	else
		self.openFlee = true
		self.currentState = self.fleeState
	end
	self.currentState:start()
end

function RaidFleeState.stop( self )
	self.started = false
	self.currentState:stop()
end

function RaidFleeState.isOutsideFleeCircle( self )
	local toCenter = self.unit.character.worldPosition - self.center
	toCenter.z = 0
	return toCenter:length2() >= self.fleeRadius * self.fleeRadius
end

function RaidFleeState.onFixedUpdate( self, dt )
	if not self.started then return end
	if self.swims then
		-- Same as the unit's own pathing, which turns cliff avoidance off while swimming
		local cliffAvoidance = not self.unit.character:isSwimming()
		self.pathingState:sv_setCliffAvoidance( cliffAvoidance )
		self.fleeState.cliffAvoidance = cliffAvoidance
	end
	if not self.openFlee then
		if self:isOutsideFleeCircle() then
			self.openFlee = true
			self.currentState:stop()
			self.currentState = self.fleeState
			self.currentState:start()
		elseif self.pathingState:isDone() then
			-- Blocked or interrupted; try again. A raider that is truly stuck is released by the unit's own stuck check
			self.pathingState:stop()
			self.pathingState:start()
			self.pathingState:sv_setDestination( self.pathDestination )
		end
	end
	self.currentState:onFixedUpdate( dt )
end

function RaidFleeState.onUnitUpdate( self, dt )
	if not self.started then return end
	self.currentState:onUnitUpdate( dt )
end

-- Never done by itself; the unit stops fleeing through its raid flee timeout
function RaidFleeState.isDone( self )
	return false, ""
end

function RaidFleeState.getMovementDirection( self )
	return self.currentState:getMovementDirection()
end

function RaidFleeState.getFacingDirection( self )
	return self.currentState:getFacingDirection()
end

function RaidFleeState.getMovementType( self )
	return self.currentState:getMovementType()
end

function RaidFleeState.getWantsJump( self )
	return self.currentState:getWantsJump()
end

function RaidFleeState.getWantsCrouch( self )
	return self.currentState:getWantsCrouch()
end
