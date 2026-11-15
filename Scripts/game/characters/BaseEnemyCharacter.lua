dofile( "$CONTENT_DATA/Scripts/game/managers/RaidManager.lua" )

BaseEnemyCharacter = class( nil )

function BaseEnemyCharacter.server_onCreate( self )
	self.character.publicData = {}
end

function BaseEnemyCharacter.cl_isLocalPlayerInRaid( self )
	local center = RaidManager.Cl_GetRaidCenter( self.character:getWorld().id, self.cl.raidKey )
	local player = sm.localPlayer.getPlayer()
	local playerCharacter = player and player.character
	if center == nil or not sm.exists( playerCharacter ) then
		return false
	end
	self.cl.inRaid = RaidManager.IsWithinRaidRadius( ( center - playerCharacter.worldPosition ):length2(), self.cl.inRaid )
	return self.cl.inRaid
end

function BaseEnemyCharacter.client_onUpdate( self, dt )
	-- update marker
	if self.cl.raidKey then
		self:cl_showCompassIcon( self:cl_isLocalPlayerInRaid() )
	end
end

function BaseEnemyCharacter.sv_e_markEnemy( self, data )
	data.tick = sm.game.getServerTick()
    self.network:setClientData( data )
end

function BaseEnemyCharacter.cl_showCompassIcon( self, show )
	if not g_compassHud or ( self.cl.compassIconShown or false ) == show then
		return
	end
	self.cl.compassIconShown = show
	local name = "enemy"..self.character.id
	if show then
		local icon = "icon_farmraid_compass_bot.png"
		if self.character:getCharacterType() == unit_farmbot then
			icon = "icon_farmraid_compass_farmbot.png"
		end
		g_compassHud:compassAddIcon( name, icon, false, 8, 12 )
		g_compassHud:compassSetIconHost( name, self.character )
		g_compassHud:setVisible( name, true )
	else
		g_compassHud:compassRemoveIcon( name )
	end
end

function BaseEnemyCharacter.cl_unmark( self )
	self:cl_showCompassIcon( false )
	if self.cl.markEffect then
		self.cl.markEffect:stop()
		self.cl.markEffect:destroy()
		self.cl.markEffect = nil
	end
	self.cl.raidKey = nil
end

function BaseEnemyCharacter.client_onClientDataUpdate( self, data, channel )
	if channel == 1 then
		if data.raidKey then
			self.cl.raidKey = data.raidKey
		else
			self.cl.markEffect = sm.effect.createEffect( "EnemyMarker", self.character, nil, sm.effect.axis.all )
			self.cl.markEffect:setOffsetPosition( sm.vec3.new( 0, 0, self.character:getHeight() ) )
			self.cl.markEffect:start()
			self:cl_showCompassIcon( true )
		end
	end
end

function BaseEnemyCharacter.client_onCreate( self )
	self.character.clientPublicData = {}
end

function BaseEnemyCharacter.client_onDestroy( self )
	self:cl_unmark()
end