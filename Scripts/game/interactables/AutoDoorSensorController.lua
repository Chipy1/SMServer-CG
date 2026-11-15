AutoDoorSensorController = class( nil )
AutoDoorSensorController.maxParentCount = 0
AutoDoorSensorController.maxChildCount = 2
AutoDoorSensorController.connectionInput = sm.interactable.connectionType.none
AutoDoorSensorController.connectionOutput = sm.interactable.connectionType.logic

local DoorOpenIdleTime = 10 * 40
local ScannerDuration = 3 * 40
local DoorCheckTickFrequency = 0.3 * 40
local TriggerAreaSize = sm.vec3.new( 6.5, 6.5, 3.5 )
local TriggerOffset = sm.vec3.new( 0, 0, -4 )
local EffectOffset1 = sm.vec3.new( 0, -0.4, 1.5 )
local EffectOffset2 = sm.vec3.new( 0.1, 0.7, 1.5 )
local AutoDoorSensorUuid = sm.uuid.new( "0861357a-79bd-44ac-8e8f-45c7f289875d" )

local function GetDoorStatus( door )
    local trackProgress = door.publicData.getTrackProgress()
    local fullyClosed = trackProgress.trackIndex == 1 and trackProgress.segmentIndex == 1 and trackProgress.segmentProgress == 0
    local fullyOpened = trackProgress.trackIndex == 1 and trackProgress.segmentIndex == 2 and trackProgress.segmentProgress == 1
    return fullyClosed, fullyOpened
end

function AutoDoorSensorController.server_onCreate( self )
    self.sv = {}
    self.sv.door = nil
    self.sv.tickCounter = 0
    self.sv.areaTrigger = sm.areaTrigger.createBox( TriggerAreaSize , self.shape.worldPosition + self.shape.worldRotation * TriggerOffset, self.shape.worldRotation, sm.areaTrigger.filter.character )

    -- 0 = check door
    -- 1 = fully closed
    -- 2 = fully open
    -- 3 = scanning
    -- 4 = closing/opening
    self.sv.state = 0
end

function AutoDoorSensorController.server_onDestroy( self )
    self.sv.areaTrigger:destroy()
    self.sv.areaTrigger = nil
end

function AutoDoorSensorController.server_onFixedUpdate( self )
    if self.sv.state == 0 then
        self.sv.tickCounter = self.sv.tickCounter + 1
        if self.sv.tickCounter >= DoorCheckTickFrequency then
            self.sv.tickCounter = 0
            local contacts = sm.physics.getSphereContacts( self.shape:getWorldPosition() + sm.vec3.new( 0, 0, -5 ), 2 )
            for _, harvestable in ipairs( contacts.harvestables ) do
                if harvestable.publicData and harvestable:isKinematic() then
                    self.sv.door = harvestable
                    local fullyClosed, fullyOpened = GetDoorStatus( harvestable )
                    self.network:setClientData( fullyClosed )
                    self.sv.state = fullyClosed and 1 or ( fullyOpened and 2 or 4 )
                    break
                end
            end
        end
    else
        local contents = self.sv.areaTrigger:getContents()
        local hasCharacterInTrigger = #contents > 0

        if self.sv.state == 1 then -- Fully closed
            if hasCharacterInTrigger then
                local characterPos = contents[1].worldPosition
                local localPos = self.shape:transformPoint( characterPos )
                local offset = localPos.x < 0.0 and EffectOffset1 or EffectOffset2
                local rotation = self.shape.worldRotation * ( localPos.x < 0.0 and sm.quat.identity() or sm.quat.new( 0, 0, 1, 0. ) )
                sm.effect.playEffect( "Growlab - Doorscannerlaser_activate", self.shape.worldPosition + self.shape.worldRotation * offset, nil, rotation )
                self.network:setClientData( false )
                self.sv.tickCounter = 0
                self.sv.state = 3
            end
        elseif self.sv.state == 2 then -- Fully open
            self.sv.tickCounter = not hasCharacterInTrigger and ( self.sv.tickCounter + 1 ) or 0
            if self.sv.tickCounter >= DoorOpenIdleTime then
                sm.event.sendToHarvestable( self.sv.door, "sv_e_activate", nil, sm.event.types.instant )
                self.sv.state = 4
            end
        elseif self.sv.state == 3 then -- Scanning
            self.sv.tickCounter = self.sv.tickCounter + 1
            if self.sv.tickCounter >= ScannerDuration then
                if hasCharacterInTrigger then
                    for _, child in ipairs( self.interactable:getChildren( sm.interactable.connectionType.logic ) ) do
                        if child.shape:getShapeUuid() == AutoDoorSensorUuid then
                            sm.event.sendToInteractable( child, "sv_e_blink", nil, sm.event.types.instant )
                        end
                    end
                    sm.event.sendToHarvestable( self.sv.door, "sv_e_activate", nil, sm.event.types.instant )
                    self.sv.state = 4
                else
                    self.network:setClientData( true )
                    self.sv.state = 1
                end
            end
        elseif self.sv.state == 4 then -- Closing/Opening
            local fullyClosed, fullyOpened = GetDoorStatus( self.sv.door )
            if fullyClosed then
                self.network:setClientData( true )
                self.sv.state = 1
            elseif fullyOpened then
                self.sv.state = 2
            end
        end
    end
end

function AutoDoorSensorController.client_onCreate( self )
    self.cl = {}
    self.cl.idleEffect1 = sm.effect.createEffect( "Growlab - Doorscannerlaser", self.shape )
    self.cl.idleEffect2 = sm.effect.createEffect( "Growlab - Doorscannerlaser", self.shape )
    self.cl.idleEffect1:setOffsetPosition( EffectOffset1 )
    self.cl.idleEffect2:setOffsetPosition( EffectOffset2 )
    self.cl.idleEffect2:setOffsetRotation( sm.quat.new( 0, 0, 1, 0. ) )
end

function AutoDoorSensorController.client_onDestroy( self )
    self.cl.idleEffect1:destroy()
    self.cl.idleEffect2:destroy()
end

function AutoDoorSensorController.client_onClientDataUpdate( self, show )
    if show then
        self.cl.idleEffect1:start()
        self.cl.idleEffect2:start()
    else
        self.cl.idleEffect1:stopImmediate()
        self.cl.idleEffect2:stopImmediate()
    end
end
