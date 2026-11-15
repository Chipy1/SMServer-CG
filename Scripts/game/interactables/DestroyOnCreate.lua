DestroyOnCreate = class( nil )

function DestroyOnCreate.server_onCreate( self )
	self.shape:destroyShape()
end
