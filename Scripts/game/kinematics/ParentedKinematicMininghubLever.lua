dofile( "$CONTENT_DATA/Scripts/game/kinematics/ParentedKinematic.lua" )
dofile( "$CONTENT_DATA/Scripts/game/quests/ActivateMininghubQuest.lua" )

ParentedKinematicMininghubLever = class( ParentedKinematic )

local MininghubLightManagerUuid = sm.uuid.new( "53b762b3-f2f9-4faa-beca-750fa99c31c2" )

-- Server

local MininghubCell = { x = -2, y = -1 }

function ParentedKinematicMininghubLever.server_onCreate( self )
	ParentedKinematic.server_onCreate( self )
	local progressData = self.sv.trackInstances["track"].progressData
	local onFirstNode = progressData.segmentIndex == 1 and progressData.segmentProgress == 0
	self.sv.used = not onFirstNode
	self.network:setClientData( { usable = onFirstNode }, 3 )
end

function ParentedKinematicMininghubLever.sv_n_activate( self )
	if self.sv.used or KinematicManager.Sv_IsMoving( self.sv.tileStorageKey, "mininghub.pylon" ) then
		return
	end
	self.sv.used = true
	self:sv_activate()
	self.network:setClientData( { usable = false }, 3 )
	QuestManager.Sv_SendEvent( "mininghub_lever_pulled", { position = self.harvestable.worldPosition } )
	sm.scriptableObject.createScriptableObject( MininghubLightManagerUuid, { position = self.harvestable.worldPosition }, self.harvestable:getWorld() )
	KinematicManager.Sv_Activate( self.sv.tileStorageKey, "mininghub.pylon", { persistent = true }, true )
	KinematicManager.Sv_Activate( self.sv.tileStorageKey, "activateLights", { persistent = true }, true )
end

function ParentedKinematicMininghubLever.server_onFixedUpdate( self )
	ParentedKinematic.server_onFixedUpdate( self )

	if self.sv.used and not self.sv.retractCheck and not KinematicManager.Sv_IsMoving( self.sv.tileStorageKey, "mininghub.pylon" ) then
        local world = WorldManager.Sv_GetWorld( "undergroundworld1" )
        if sm.exists( world ) and world:isCellLoadedServer( MininghubCell.x, MininghubCell.y ) then
            KinematicManager.Sv_ResetTrack( self.sv.tileStorageKey, "mininghub.pylon" )
            self.sv.retractCheck = true
        end
    end

end

-- Client

function ParentedKinematicMininghubLever.client_onCreate( self )
	ParentedKinematic.client_onCreate( self )
	self.cl.usable = true
end

function ParentedKinematicMininghubLever.client_onClientDataUpdate( self, data, channel )
	if channel == 3 then
		self.cl.usable = data.usable
	else
		ParentedKinematic.client_onClientDataUpdate( self, data, channel )
	end
end

function ParentedKinematicMininghubLever.client_canInteract( self )
	if not self.cl.usable then
		return false
	end
	if DialogManager.Cl_IsRunning() then
		return false
	end
	local stage = QuestManager.Cl_GetQuestStage( "quest_activate_mininghub" )
	if stage == ActivateMininghubQuest.Stages.activate_pylon then
		sm.gui.setInteractionText( "", sm.gui.getKeyBinding( "Use", true ), "#{INTERACTION_USE}" )
		return true
	end
	return false
end

function ParentedKinematicMininghubLever.client_onInteract( self, character, state )
	if state == true then
		sm.effect.playEffect( "Elevator Button", self.harvestable.worldPosition )
		self.network:sendToServer( "sv_n_activate" )
	end
end
