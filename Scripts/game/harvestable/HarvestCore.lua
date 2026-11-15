-- HarvestCore.lua --

dofile( "$CONTENT_DATA/Scripts/game/survival_units.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/TutorialManager.lua" )

local MultitoolRecipes = {
	[tostring( ITEMS.obj_harvest_wood )] = { itemId = ITEMS.blk_scrapwood, quantity = 20 },
	[tostring( ITEMS.obj_harvest_metal )] = { itemId = ITEMS.blk_scrapmetal, quantity = 20 },
	[tostring( ITEMS.obj_harvest_stone )] = { itemId = ITEMS.blk_scrapstone, quantity = 20 },
	[tostring( ITEMS.obj_harvest_metal2 )] = { itemId = ITEMS.blk_metal1, quantity = 20 },
	[tostring( ITEMS.obj_harvest_wood2 )] = { itemId = ITEMS.blk_scrapwood, quantity = 40 },
	[tostring( ITEMS.obj_harvest_crystal )] = { itemId = ITEMS.blk_mineralblue, quantity = 20 },
}

---@class HarvestCore : ShapeClass
---@field s_users Player[]
---@field s_refineElapsed number
---@field c_effect Effect
---@field c_refineElapsed number
---@field c_refining boolean
HarvestCore = class( nil )

local RefineTime = 2.8
local TutorialActivationDistance = 7.5
local SyncInterval = 0.1

function HarvestCore.server_onCreate( self )
	self.s_users = {}
	self.s_refineElapsed = 0
	self.s_syncElapsed = 0
end

function HarvestCore.server_onDestroy( self )
	if self.s_users then
		for _, user in ipairs( self.s_users ) do
			if sm.exists( user ) then
				sm.event.sendToPlayer( user, "sv_e_setRefiningState", false )
			end
		end
	end
end

function HarvestCore.client_onDestroy( self )
	self.c_effect:destroy()
end

function HarvestCore.client_onCreate( self )
	self.c_effect = sm.effect.createEffect( "Harvestable - Marker", self.interactable )
	self.c_effect:start()

	self.c_refineElapsed = 0
	self.c_refining = false

	local myCharacter = sm.localPlayer.getPlayer().character
	if sm.exists( myCharacter ) then
		local distance2 = ( myCharacter.worldPosition - self.shape.worldPosition ):length2()
		if distance2 <= TutorialActivationDistance^2 then
			TutorialManager.Cl_TutorialEvent( TutorialEvent.RefineByHand )
		end
	end
end

function HarvestCore.client_canInteract( self, character )
	if character:getCharacterType() == unit_mechanic and not character:isTumbling() then
		sm.gui.setInteractionText( "", sm.gui.getKeyBinding( "Use", true ), "#{INTERACTION_REFINE}" )
		return true
	end
	return false
end

function HarvestCore.client_onInteract( self, user, state )
	local recipe = MultitoolRecipes[tostring( self.shape.shapeUuid )]
	local player = user:getPlayer()

	if recipe and player then
		if state and not sm.container.canCollect( player:getInventory(), recipe.itemId, recipe.quantity ) then
			NotificationManager.Cl_AddGenericNotification( "#{INFO_INVENTORY_FULL}" )
			return
		end

		self.network:sendToServer( "sv_n_setRefiningState", {
			state = state,
			player = player
		} )
	else
		NotificationManager.Cl_AddGenericNotification( "#{INFO_REQUIRES_REFINEBOT}" )
	end
end

function HarvestCore.sv_n_setRefiningState( self, data, player )
	local targetPlayer = data.player or player

	if not sm.exists( targetPlayer ) then
		return
	end

	if data.state then
		for _, user in ipairs( self.s_users ) do
			if user == targetPlayer then
				return
			end
		end

		table.insert( self.s_users, targetPlayer )
	else
		removeFromArray( self.s_users, function( user )
			return user == targetPlayer
		end )
	end

	sm.event.sendToPlayer( targetPlayer, "sv_e_setRefiningState", data.state )
end

function HarvestCore.server_onFixedUpdate( self, dt )
	if #self.s_users > 0 then
		self.s_refineElapsed = math.min(
			self.s_refineElapsed + dt,
			RefineTime
		)

		if self.s_refineElapsed >= RefineTime then
			self:sv_refine()
			return
		end
	end

	self.s_syncElapsed = self.s_syncElapsed + dt

	if self.s_syncElapsed >= SyncInterval then
		self.s_syncElapsed = 0

		self.network:sendToClients(
			"cl_n_syncProgress",
			self.s_refineElapsed / RefineTime
		)
	end
end

function HarvestCore.cl_n_syncProgress( self, progress )
	self.c_refineElapsed = progress * RefineTime
	self.c_refining = progress < 1
end

function HarvestCore.client_onUpdate( self, dt )
	if self.c_refining then
		sm.gui.setProgressFraction(
			self.c_refineElapsed / RefineTime
		)
	end
end

function HarvestCore.sv_refine( self )
	if not sm.exists( self.shape ) then
		return
	end

	local recipe = MultitoolRecipes[tostring( self.shape.shapeUuid )]
	if not recipe then
		return
	end

	sm.container.beginTransaction()

	for _, player in ipairs( self.s_users ) do
		if sm.exists( player ) then
			if sm.container.canCollect(
				player:getInventory(),
				recipe.itemId,
				recipe.quantity
			) then
				sm.container.collect(
					player:getInventory(),
					recipe.itemId,
					recipe.quantity
				)
				break
			end
		end
	end

	if sm.container.endTransaction() then
		self.shape:destroyShape()
	end
end

--[[
dofile( "$CONTENT_DATA/Scripts/game/survival_units.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/TutorialManager.lua" )

local MultitoolRecipes = {
	[tostring( ITEMS.obj_harvest_wood )] = { itemId = ITEMS.blk_scrapwood, quantity = 20 },
	[tostring( ITEMS.obj_harvest_metal )] = { itemId = ITEMS.blk_scrapmetal, quantity = 20 },
	[tostring( ITEMS.obj_harvest_stone )] = { itemId = ITEMS.blk_scrapstone, quantity = 20 },
	[tostring( ITEMS.obj_harvest_metal2 )] = { itemId = ITEMS.blk_metal1, quantity = 20 },
	[tostring( ITEMS.obj_harvest_wood2 )] = { itemId = ITEMS.blk_scrapwood, quantity = 40 },
	[tostring( ITEMS.obj_harvest_crystal )] = { itemId = ITEMS.blk_mineralblue, quantity = 20 },
}

---@class HarvestCore : ShapeClass
---@field s_users Player[]
---@field c_effect Effect
---@field c_refining boolean|nil
---@field c_refineElapsed number|nil
HarvestCore = class( nil )

local RefineTime = 2.8
local TutorialActivationDistance = 7.5

function HarvestCore.server_onDestroy( self )
	if self.s_users then
		for _, user in ipairs( self.s_users ) do
			if sm.exists( user ) then
				sm.event.sendToPlayer( user, "sv_e_setRefiningState", false )
			end
		end
	end
end

function HarvestCore.client_onDestroy( self )
	self.c_effect:destroy()
end

function HarvestCore.client_onCreate( self )
	self.c_effect = sm.effect.createEffect( "Harvestable - Marker", self.interactable )
	self.c_effect:start()

	local myCharacter = sm.localPlayer.getPlayer().character
	if sm.exists( myCharacter ) then
		local distance2 = ( myCharacter.worldPosition - self.shape.worldPosition ):length2()
		if distance2 <= TutorialActivationDistance^2 then
			TutorialManager.Cl_TutorialEvent( TutorialEvent.RefineByHand )
		end
	end
end

function HarvestCore.client_canInteract( self, character )
	if character:getCharacterType() == unit_mechanic and not character:isTumbling() then
		sm.gui.setInteractionText( "", sm.gui.getKeyBinding( "Use", true ), "#{INTERACTION_REFINE}" )
		return true
	end
	return false
end

function HarvestCore.client_onInteract( self, user, state )
	local recipe = MultitoolRecipes[tostring( self.shape.shapeUuid )]
	local player = user:getPlayer()
	if recipe and player then
		if sm.container.canCollect( player:getInventory(), recipe.itemId, recipe.quantity ) then
			self.c_refining = state
			self.network:sendToServer( "sv_n_setRefiningState", state )
		else
			NotificationManager.Cl_AddGenericNotification( "#{INFO_INVENTORY_FULL}" )
		end
	else
		NotificationManager.Cl_AddGenericNotification( "#{INFO_REQUIRES_REFINEBOT}" )
	end
end

function HarvestCore.sv_n_setRefiningState( self, state, player )
	if state == true then
		self.s_users = self.s_users or {}
		self.s_users[#self.s_users+1] = player
	elseif self.s_users then
		removeFromArray( self.s_users, function( user ) return user == player end )
	end
	if sm.exists( player ) then
		sm.event.sendToPlayer( player, "sv_e_setRefiningState", state )
	end
end

function HarvestCore.client_onUpdate( self, dt )
	if self.c_refining == true then
		self.c_refineElapsed = self.c_refineElapsed or 0
		sm.gui.setProgressFraction( self.c_refineElapsed / RefineTime )
		self.c_refineElapsed = self.c_refineElapsed + dt
		if self.c_refineElapsed >= RefineTime then
			self.c_refining = nil
			self.c_refineElapsed = nil
			self.network:sendToServer( "sv_refine", sm.localPlayer.getPlayer() )
			sm.effect.playEffect( "Multiknife - Complete", self.shape.worldPosition )
		end
	elseif self.c_refineElapsed and self.c_refineElapsed > 0.0 then
		self.c_refineElapsed = math.max( self.c_refineElapsed - 0.25 * ( RefineTime - self.c_refineElapsed ) * dt, 0 )
	end
end

function HarvestCore.sv_refine( self, player )
	if sm.exists( self.shape ) then
		local recipe = MultitoolRecipes[tostring( self.shape.shapeUuid )]
		sm.container.beginTransaction()
		if recipe then
			sm.container.collect( player:getInventory(), recipe.itemId, recipe.quantity )
		end
		if sm.container.endTransaction() then
			self.shape:destroyShape()
		end
	end
end
]]