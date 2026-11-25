dofile "$CONTENT_DATA/Scripts/game/units/unit_util.lua"
dofile "$CONTENT_DATA/Scripts/game/units/states/RaidFleeState.lua"
dofile "$CONTENT_DATA/Scripts/game/managers/PatrolManager.lua"
dofile "$CONTENT_DATA/Scripts/achievement_common.lua"

BaseUnit = class( nil )

local VelocityBufferCount = 8

function BaseUnit.server_onDestroy( self )
	if SurvivalGame then
		if self.saved.patrolKey then
			PatrolManager.Sv_RemoveUnit( self.saved.patrolKey, self.unit )
		end
	end
	-- markedForRemoval lives in saved data: server_onDestroy currently only runs on an unload (not on game
	-- shutdown), so the mark must survive a restart and only be consumed here when the unit is truly unloaded.
	if self.saved.markedForRemoval then
		sm.unit.forceDestroy( self.unit )
		if SurvivalGame then
			if self.actorName then
				QuestActorManager.Sv_UnregisterActor( self.actorName )
			end
		end
	end
end

-- Removes the unit once its deathTickTimestamp is reached; returns true when it did.
-- A raider leftover is only destroyed when CanDespawnRaidLeftover allows it, any other unit is marked for removal.
function BaseUnit.server_onFixedUpdate( self, dt )
	local server_onUnitUpdate = self.server_onUnitUpdate
	if server_onUnitUpdate then server_onUnitUpdate(self, dt) end
	if sm.exists( self.unit ) and not self.destroyed then
		local deathTick = self.saved.deathTickTimestamp
		local reached = deathTick ~= nil and sm.game.getCurrentTick() >= deathTick
		local removing = reached and ( not self.saved.raider or CanDespawnRaidLeftover( self ) )
		if removing then
			if self.saved.raider then
				RaidManager.Sv_RemoveRaider( self.saved.raider.raidKey, self.unit )
				self.unit:destroy()
				return
			else
				self.isDirty = self.isDirty or not self.saved.markedForRemoval
				self.saved.markedForRemoval = true
			end
		end

		local character = self.unit.character
		if sm.exists( character ) then
			UpdateSwimUnderTerrainRecovery( self )
			if self.velocityBufferIndex == nil then
				self.velocityBuffer = {}
				self.velocityBufferIndex = 1
			end
			self.velocityBufferIndex = self.velocityBufferIndex + 1
			if self.velocityBufferIndex > VelocityBufferCount then
				self.velocityBufferIndex = 1
			end
			self.velocityBuffer[self.velocityBufferIndex] = character:getVelocity()
		end
	end
end

function BaseUnit.sv_e_receiveDamage( self, damageData )
	if damageData.hitPos and self.eventNoisePosition == nil then
		-- Sense damage
		self.eventNoisePosition = damageData.hitPos
	end
	self:sv_takeDamage( damageData.damage, damageData.impact, damageData.hitPos, damageData.source )
end

function BaseUnit.sv_takeDamage( self, damage, impact, hitPos, source )
    print("Unimplemented Unit 'sv_takeDamage'" )
end

function BaseUnit.sv_onDeath( self )
	if SurvivalGame then
		if self.saved.deathEvent then
			QuestManager.Sv_SendEvent( self.saved.deathEvent )
		end
		if self.saved.combatRoomName then
			CombatRoomManager.Sv_EnemyDefeated( self.saved.combatRoomName, self.unit.id )
		end
		if not self.saved.raider and isAnyOf( self.unit.character:getCharacterType(), g_robots ) then
			if ProgressionManager then
				ProgressionManager.Sv_TrySpawnGrowlabKey( self.unit )
			end
		end
	end

	if isAnyOf(self.unit.character:getCharacterType(), g_robots) then
		local playersInRange = {}
		local deathPos = self.unit.character:getWorldPosition()
		local unitWorld = self.unit.character:getWorld()

		local sqrdAchievementRange = 192 * 192 -- 3*64 == 192 (aprox 3 tiles)

		-- sm-raid-fix: a player without a character (joining/leaving or on a dedicated
		-- server) has no world; indexing it crashed the death handler.
		for _, player in ipairs(sm.player.getAllPlayers()) do
			local playerCharacter = player:getCharacter()
			if playerCharacter then
				local playerWorld = playerCharacter:getWorld()
				if unitWorld == playerWorld then
					local distSqrd = (playerCharacter:getWorldPosition() - deathPos):length2()
					if distSqrd < sqrdAchievementRange then
						table.insert(playersInRange, player.id)
					end
				end
			end
		end
		if( isAnyOf( self.unit.character:getCharacterType(), g_totebots ) ) then
			sm.achievement.addi( "5e348e50-813d-4c52-9a3f-b5605d0fdb9f", 1, playersInRange ) -- Totebots
		else
			sm.achievement.addi( tostring( self.unit.character:getCharacterType() ), 1, playersInRange )
		end
	end
	RobotOnDestroy(self)
end

function BaseUnit.sv_e_receiveTarget( self, params )
	if self.saved.targetPlayerOnly and not params.targetCharacter:isPlayer() then return end
	
    if self.unit ~= params.sendingUnit and not self.saved.raider then
		if self.eventTarget == nil then
			local sameTeam = false
			if not SurvivalGame then
				sameTeam = InSameTeam( params.targetCharacter, self.unit )
			end
			if not sameTeam then
				self.eventTarget = params.targetCharacter
			end
		end
	end
end

function BaseUnit.sv_e_tumble( self, params )
	if self.canTumble and self.idleState then
		startTumble( self, params.tumbleTickTime, self.idleState, params.tumbleVelocity )
	end
end

function BaseUnit.sv_createRaidFlee( self )
	local flee = self.unit:createState( "flee" )
	flee.movementAngleThreshold = math.rad( 180 )
	flee.maxFleeTime = 0.0
	flee.maxDeviation = 45 * math.pi / 180
	flee.debugName = "raidFleeRun"

	local pathingState = PathingState()
	pathingState:sv_onCreate( self.unit )
	pathingState:sv_setMovementType( "sprint" )
	pathingState:sv_setWaterAvoidance( true )
	pathingState.debugName = "raidFleePathing"

	local raidFlee = RaidFleeState()
	raidFlee:sv_onCreate( self.unit, pathingState, flee )
	raidFlee.debugName = "raidFlee"
	return raidFlee
end

function BaseUnit.sv_e_markForRemoval( self )
	self.saved.markedForRemoval = true
	self.isDirty = true
end

function BaseUnit.sv_m_projectileHit( self, params )
	if sm.exists( self.unit ) and sm.exists( params.attacker ) and self.isInCombat == false and InSameWorld( params.world, self.unit ) then
		local distanceToProjectile = ( self.unit.character.worldPosition - params.position ):length()
		if distanceToProjectile <= 4.0 then
			local isEnemyUnit = type( params.attacker ) == "Unit" and not InSameTeam( self.unit, params.attacker )
			if type( params.attacker ) == "Player" or isEnemyUnit then
				if self.eventTarget == nil then
					self.eventTarget = params.attacker:getCharacter()
				end
			elseif type( params.attacker ) == "Shape" then
				if self.eventNoisePosition == nil then
					self.eventNoisePosition = params.attacker.worldPosition
				end
			end
		end
	end
end

function BaseUnit.sv_m_projectileFire( self, params )
	if sm.exists( self.unit ) and self.isInCombat == false and InSameWorld( params.world, self.unit ) then
		local distanceToShooter = ( self.unit.character.worldPosition - params.position ):length()
		if distanceToShooter <= 10.0 then
			local isEnemyUnit = type( params.attacker ) == "Unit" and not InSameTeam( self.unit, params.attacker )
			if type( params.attacker ) == "Player" or isEnemyUnit then
				if self.eventTarget == nil then
					if sm.exists( params.attacker ) then
						self.eventTarget = params.attacker:getCharacter()
					else
						self.eventNoisePosition = params.position
					end
				end
			elseif type( params.attacker ) == "Shape" then
				if self.eventNoisePosition == nil then
					self.eventNoisePosition = params.position
				end
			end
		end
	end
end

function BaseUnit.sv_m_projectileBounce( self, params )
	if self.isInCombat == false and sm.exists( self.unit ) and InSameWorld( params.world, self.unit ) then
		local distanceToBounceSqr = ( self.unit.character.worldPosition - params.position ):length2()
		if distanceToBounceSqr <= 16.0 then
			local type = type( params.attacker )
			local attackerExists = sm.exists( params.attacker )
			if type == "Player" or ( type == "Unit" and attackerExists and not InSameTeam( self.unit, params.attacker ) ) then
				if self.eventTarget == nil then
					self.eventTarget = attackerExists and params.attacker:getCharacter() or nil
					if self.eventTarget == nil then
						self.eventNoisePosition = params.position
					end
				end
			elseif type == "Shape" and self.eventNoisePosition == nil then
				self.eventNoisePosition = params.position
			end
		end
	end
end

function BaseUnit.sv_m_collision( self, params )
	if sm.exists( self.unit ) and self.isInCombat == false and InSameWorld( params.world, self.unit ) then
		local soundReach = math.min( math.max( math.log( 1 + params.impactEnergy ) * 10.0, 0.0 ), 40.0 )
		local betweenVec = self.unit.character.worldPosition - params.position
		betweenVec.z = betweenVec.z * HEIGHT_DISTANCE_MULTIPLIER
		local distanceToSound = betweenVec:length()
		if distanceToSound <= soundReach then
			if self.eventNoisePosition == nil then
				self.eventNoisePosition = params.position
			end
		end
	end
end
