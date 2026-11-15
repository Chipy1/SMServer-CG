dofile( "$CONTENT_DATA/Scripts/game/characters/BaseCharacter.lua" )
dofile( "$CONTENT_DATA/Scripts/game/characters/shared_animation.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/DrillbotManager.lua" )

CinematicDrillbotCharacter = class( BaseCharacter )

local DrillbotCinematicAnimation = "drillbot_introcinematic"
-- Custom game: the client animation table does not exist on a dedicated server,
-- so the intro animation is cleared after the known clip length instead.
local DrillbotCinematicAnimationDurationTicks = math.ceil( 48.666667 * 40 )

function CinematicDrillbotCharacter.server_onCreate( self )
	BaseCharacter.server_onCreate( self )
	self.sv.animationState = {}
end

function CinematicDrillbotCharacter.client_onCreate( self )
	BaseCharacter.client_onCreate( self )
	self.cl.sphereJointEffects = {}
end

function CinematicDrillbotCharacter.client_onDestroy( self )
	for _, sphereEffect in ipairs( self.cl.sphereJointEffects ) do
		if sm.exists( sphereEffect ) and sphereEffect:isPlaying() then
			sphereEffect:destroy()
		end
	end
end

function CinematicDrillbotCharacter.client_onGraphicsLoaded( self )
	self.cl.animations = self.cl.animations or {}

	local animTable = self.cl.animations
	local char = self.character
	-- Idle pose (looping)
	INIT_ANIMATION( animTable, char, "drillbot_logopose" )

	-- Event animations (return to idle when done)
	INIT_ANIMATION( animTable, char, "drillbot_introcinematic", { nextAnimation = "drillbot_logopose" } )

	BaseCharacter.client_onGraphicsLoaded( self )

	-- Start in idle pose
	if self.cl.pendingAnimationState then
		self:client_onClientDataUpdate( self.cl.pendingAnimationState, 1 )
		self.cl.pendingAnimationState = nil
	else
		self:cl_setCurrentAnimation( "drillbot_logopose" )
	end
end

-- Called by the unit via sm.event.sendToCharacter to sync animation state
function CinematicDrillbotCharacter.sv_e_setAnimationState( self, params )
	self.sv.animationState = params
	self.network:setClientData( self.sv.animationState )
end

function CinematicDrillbotCharacter.server_onFixedUpdate( self, dt )
	local animationState = self.sv.animationState
	if not animationState.currentEvent or not animationState.startTick then
		return
	end

	local durationTicks
	if self.cl == nil or g_isDedicatedServer == true then
		-- Dedicated server: no client animation data, use the fixed clip length.
		durationTicks = DrillbotCinematicAnimationDurationTicks
	else
		-- Host/client: the animation table tells how long the clip actually is.
		if not self.cl.graphicsLoaded then
			return
		end
		local animation = self.cl.animations[DrillbotCinematicAnimation]
		if not ( animation and animation.info ) then
			return
		end
		durationTicks = math.ceil( animation.info.duration * 40.0 )
	end

	if sm.game.getCurrentTick() - animationState.startTick >= durationTicks then
		self.sv.animationState = {}
		self.network:setClientData( self.sv.animationState )
	end
end

function CinematicDrillbotCharacter.client_onClientDataUpdate( self, data, channel )
	if not self.cl.graphicsLoaded then
		self.cl.pendingAnimationState = data
		return
	end

	if data and data.currentEvent and data.currentEvent == "event.cinematic.drillbotdrop" then
		-- An event animation is active, sync to it
		if self.cl.animations[DrillbotCinematicAnimation] then
			if self.cl.animator.currentAnimation ~= DrillbotCinematicAnimation then
				self:cl_setCurrentAnimation( DrillbotCinematicAnimation )
			end
			-- Calculate elapsed time from startTick and set animation time accordingly
			if data.startTick then
				local elapsedTicks = sm.game.getCurrentTick() - data.startTick
				local elapsedTime = elapsedTicks / 40.0
				local animation = self.cl.animations[DrillbotCinematicAnimation]
				if animation.info and animation.info.looping then
					animation.time = elapsedTime % animation.info.duration
				else
					animation.time = elapsedTime
				end
			end
		end
	else
		-- No active event, return to idle pose
		if self.cl.animator.currentAnimation ~= "drillbot_logopose" then
			self:cl_setCurrentAnimation( "drillbot_logopose" )
		end
	end
end

function CinematicDrillbotCharacter.client_onUpdate( self, deltaTime )
	BaseCharacter.client_onUpdate( self, deltaTime )
	if self.cl.graphicsLoaded then
		DrillbotManager.Cl_UpdateSphereJointEffects( self.character, self.character, self.cl.sphereJointEffects )
	end
end
