dofile( "$CONTENT_DATA/Scripts/game/interactables/Chest.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/QuestManager.lua" )
dofile( "$CONTENT_DATA/Scripts/game/quests/EndGameQuest.lua" )

---@class ShipCompartment : Chest
ShipCompartment = class( Chest )

function ShipCompartment.client_canInteract( self )
	-- The locker only opens once the player has reached the crashed ship.
	local stage = QuestManager.Cl_GetQuestStage( "quest_endgame" )
	return stage ~= nil and stage >= EndGameQuest.Stages.pickup_photo
end

function ShipCompartment.client_onInteract( self, character, state )
	Chest.client_onInteract( self, character, state )
	-- Prevent dropping the quest photo to the ground, where it could be lost forever.
	if state and self.cl.gui then
		self.cl.gui:setAllowDrop( false )
	end
end
