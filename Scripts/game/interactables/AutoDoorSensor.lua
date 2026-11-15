AutoDoorSensor = class( nil )
AutoDoorSensor.maxParentCount = 1
AutoDoorSensor.maxChildCount = 0
AutoDoorSensor.connectionInput = sm.interactable.connectionType.logic
AutoDoorSensor.connectionOutput = sm.interactable.connectionType.none

local SensorUvFrequency = 0.4

function AutoDoorSensor.sv_e_blink( self )
    self.network:sendToClients( "cl_n_blink" )
end

function AutoDoorSensor.client_onCreate( self )
    self.cl = {}
    self.cl.counter = 0
    self.cl.blink = false
    self.interactable:setUvFrameIndex( 0 )
end

function AutoDoorSensor.client_onUpdate( self, dt )
    if self.cl.blink then
        self.cl.counter = self.cl.counter + dt
        if self.cl.counter >= SensorUvFrequency then
            self.interactable:setUvFrameIndex( 0 )
            self.cl.blink = false
        end
    end
end

function AutoDoorSensor.cl_n_blink( self )
    self.interactable:setUvFrameIndex( 1 )
    self.cl.blink = true
    self.cl.counter = 0
end
