
Boombox = class()
Boombox.keepActiveOnLift = true
Boombox.maxParentCount = 1
Boombox.connectionInput = sm.interactable.connectionType.logic
Boombox.colorNormal = sm.color.new( 0x6238f7ff )
Boombox.colorHighlight = sm.color.new( 0x864ff2ff )

function Boombox.sv_n_syncInteract( self )
    if not self.interactable:getSingleParent() then
        self.interactable.active = not self.interactable.active
    end
end

function Boombox.server_onFixedUpdate( self )
    local parent = self.interactable:getSingleParent()
    if parent and self.interactable.active ~= parent.active then
        self.interactable.active = parent.active
    end
end

function Boombox.client_onCreate( self )
    self.cl = {}
    self.cl.audioEffect = sm.effect.createEffect( "Boombox - Reciever", self.interactable )
    self.cl.wasActive = false
end

function Boombox.client_onDestroy( self )
    if self.cl.audioEffect then
        self.cl.audioEffect:stopImmediate()
        self.cl.audioEffect:destroy()
    end
end

function Boombox.client_canInteract( self )
    return true
end

function Boombox.client_onInteract( self, character, state )
    if state then
        if self.interactable:getSingleParent() then
            sm.gui.displayAlertText( "#{ALERT_CONTROL_OVERRIDE}", 4, true )
        else
            self.network:sendToServer( "sv_n_syncInteract" )
        end
    end
end

function Boombox.client_onFixedUpdate( self )
    if self.cl.wasActive ~= self.interactable.active then
        if self.interactable.active then
            self.cl.audioEffect:start()
        else
            self.cl.audioEffect:stopImmediate()
        end
        self.cl.wasActive = self.interactable.active
    end
end