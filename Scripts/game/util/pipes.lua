dofile( "$CONTENT_DATA/Scripts/game/survival_shapes.lua" )

ContainerUuids = {
	obj_container_gas,
	obj_container_battery,
	obj_container_water,
	obj_container_seed,
	obj_container_fertilizer,
	obj_container_ammo,
	obj_container_chest,
	obj_container_chest_looting,
	obj_container_chemical,
	obj_craftbot_refinery,
	obj_container_XXL_chest,
	obj_container_smallchest_pipe
}

PipeUuids = {
	obj_pneumatic_pipe_01,
	obj_pneumatic_pipe_02,
	obj_pneumatic_pipe_03,
	obj_pneumatic_pipe_04,
	obj_pneumatic_pipe_05,
	obj_pneumatic_pipe_bend,
	obj_pneumatic_pipe_t
}

for _,v in ipairs( ContainerUuids ) do assert( v ) end
for _,v in ipairs( PipeUuids ) do assert( v ) end

PipeState = { off = 1, invalid = 2, connected = 3, valid = 4 }

function RecursePipedShapeGraph( parent, setMarkedShapes, fnOnVertex )
	setMarkedShapes[parent.shape:getId()] = true

	-- Iterative DFS: same visitation order as the recursive version, but no Lua/C stack depth limit.
	local stackVertex = { parent }
	local stackNeighbours = { parent.shape:getPipedNeighbours() }
	local stackIndex = { 1 }
	local stackDepth = 1

	while stackDepth > 0 do
		local neighbours = stackNeighbours[stackDepth]
		local neighbourIndex = stackIndex[stackDepth]

		if neighbourIndex > #neighbours then
			stackVertex[stackDepth] = nil
			stackNeighbours[stackDepth] = nil
			stackIndex[stackDepth] = nil
			stackDepth = stackDepth - 1
		else
			stackIndex[stackDepth] = neighbourIndex + 1
			local pipedShape = neighbours[neighbourIndex]
			local shapeId = pipedShape:getId()

			if setMarkedShapes[shapeId] == nil then
				local parentVertex = stackVertex[stackDepth]
				local parentPath = parentVertex.shapesOnPath
				local pathLength = #parentPath

				local vertex = {
					shape = pipedShape,
					childs = {},
					distance = parentVertex.distance + 1,
					shapesOnPath = {},
				}
				for pathIndex = 1, pathLength do
					vertex.shapesOnPath[pathIndex] = parentPath[pathIndex]
				end
				vertex.shapesOnPath[pathLength + 1] = pipedShape

				local childs = parentVertex.childs
				childs[#childs + 1] = vertex

				-- Callback to allow for custom traversal behaviours
				local recurse = true
				if fnOnVertex then
					recurse = fnOnVertex( vertex, parentVertex )
				end

				if recurse then
					setMarkedShapes[shapeId] = true
					stackDepth = stackDepth + 1
					stackVertex[stackDepth] = vertex
					stackNeighbours[stackDepth] = pipedShape:getPipedNeighbours()
					stackIndex[stackDepth] = 1
				end
			end
		end
	end
end

function ConstructPipedShapeGraph( shape, fnOnVertex )
	local root = { childs = {}, shape = shape, shapesOnPath = {}, distance = 0 }
	RecursePipedShapeGraph( root, {}, fnOnVertex )
	return root
end

function FindContainerToCollectTo( containers, itemUid, amount )
	local canCollect = sm.container.canCollect
	for index = 1, #containers do
		local container = containers[index]
		if canCollect( container.shape:getInteractable():getContainer(), itemUid, amount ) then
			return container
		end
	end
end

function FindContainerToSpendFrom( containers, itemUid, amount )
	local canSpend = sm.container.canSpend
	for index = 1, #containers do
		local container = containers[index]
		if canSpend( container.shape:getInteractable():getContainer(), itemUid, amount ) then
			return container
		end
	end
end

PipeStateOverrideTable = {
	[PipeState.off] = {
		[PipeState.off] = false,
		[PipeState.invalid] = true,
		[PipeState.connected] = true,
		[PipeState.valid] = true,
	},
	[PipeState.invalid] = {
		[PipeState.off] = false,
		[PipeState.invalid] = false,
		[PipeState.connected] = false,
		[PipeState.valid] = false,
	},
	[PipeState.connected] = {
		[PipeState.off] = false,
		[PipeState.invalid] = true,
		[PipeState.connected] = false,
		[PipeState.valid] = true,
	},
	[PipeState.valid] = {
		[PipeState.off] = false,
		[PipeState.invalid] = true,
		[PipeState.connected] = false,
		[PipeState.valid] = false,
	},
}

function LightUpPipes( arrayPipes, fnOverride )
	local overrides = PipeStateOverrideTable
	for index = 1, #arrayPipes do
		local pipe = arrayPipes[index]
		local shape = pipe.shape
		local state = pipe.state
		if sm.exists( shape ) then
			local pipeGlow = 1.0

			if fnOverride then
				state, pipeGlow = fnOverride( pipe )
				if pipeGlow == nil then
					pipeGlow = 1.0
				end
			end

			local interactable = shape:getInteractable()
			if interactable then
				local currentState = interactable:getUvFrameIndex() + 1
				local stateOverrides = overrides[currentState]
				if stateOverrides and stateOverrides[state] then
					if currentState ~= state then
						interactable:setUvFrameIndex( state - 1 )
					end
					interactable:setGlowMultiplier( pipeGlow )
				end
			end
		end
	end
end

PipeEffectNode = class()

function PipeEffectNode.shapeExists( self )
	return sm.exists( self.shape )
end

function PipeEffectNode.getWorldPosition( self )
	local point = self.point
	if point then
		return self.shape:transformLocalPoint( point )
	end
	return self.shape:getWorldPosition()
end

PipeEffectPlayer = class()

local function ValidatePath( shapeList )
	local count = #shapeList
	if count == 0 then
		return shapeList
	end

	for index = 1, count do
		local value = shapeList[index]
		if type( value ) == "Shape" and not value:isPipe() then
			local neighbourIndex = index - 1
			if index == 1 then
				neighbourIndex = index + 1
			end

			if neighbourIndex <= count then
				local offsets = value:getPipeOffsets()
				local offsetCount = offsets and #offsets or 0
				if offsetCount > 0 then
					local subdivideRatio = sm.construction.constants.subdivideRatio
					local toPoint = shapeList[neighbourIndex]:getWorldPosition()
					local toX, toY, toZ = toPoint.x, toPoint.y, toPoint.z
					local closestOffset
					local closestDistance = math.huge

					for offsetIndex = 1, offsetCount do
						local offset = offsets[offsetIndex]
						local fromPoint = value:transformLocalPoint( offset )
						local dx = fromPoint.x - toX
						local dy = fromPoint.y - toY
						local dz = fromPoint.z - toZ
						local distanceSqr = dx * dx + dy * dy + dz * dz
						if distanceSqr < closestDistance then
							closestDistance = distanceSqr
							closestOffset = offset
						end
					end

					if closestOffset then
						local node = PipeEffectNode()
						node.shape = value
						node.point = closestOffset * subdivideRatio
						shapeList[index] = node
					end
				end
			end
		end
	end

	return shapeList
end

function PipeEffectPlayer.onCreate( self )
	self.effectTasks = {}
end

function PipeEffectPlayer.onDestroy( self )
	local effectTasks = self.effectTasks
	for index = 1, #effectTasks do
		local effect = effectTasks[index].effect
		if effect then
			effect:destroy()
		end
	end
	self.effectTasks = {}
end

function PipeEffectPlayer.pushShapeEffectTask( self, shapeList, item, delay, minimumDuration )

	shapeList = ValidatePath( shapeList )

	assert( item )
	assert( #shapeList > 0, "Pipe effect path is empty" )

	local effect = sm.effect.createEffect( "ShapeRenderable" )
	if sm.item.isTool( item ) then
		item = GetToolProxyItem( item )
	end
	local bounds = sm.item.getShapeSize( item )
	assert( bounds )
	effect:setParameter( "uuid", item )
	effect:setPosition( shapeList[1]:getWorldPosition() )

	local scale = sm.construction.constants.subdivideRatio / ( ( bounds.x + bounds.y + bounds.z ) / 3.0 )
	effect:setScale( sm.vec3.new( scale, scale, scale ) )

	self:pushEffectTask( shapeList, effect, delay, minimumDuration )
end

function PipeEffectPlayer.pushEffectTask( self, shapeList, effect, delay, minimumDuration )
	local count = #shapeList
	minimumDuration = minimumDuration or PIPE_MINIMUM_DURATION or 2.0

	local duration = count * ( DURATION_PER_PIPE or 0.025 )
	if duration < minimumDuration then
		duration = minimumDuration
	end

	self.effectTasks[#self.effectTasks + 1] = {
		shapeList = shapeList,
		effect = effect,
		progress = 0,
		delay = delay or 0,
		delayProgress = 0,
		minimumDuration = minimumDuration,
		duration = duration,
		span = count > 1 and ( 1.0 / ( count - 1 ) ) or 1.0,
	}
end

function PipeEffectPlayer.update( self, dt )
	local effectTasks = self.effectTasks
	local floor = math.floor
	for index = #effectTasks, 1, -1 do
		local task = effectTasks[index]

		if task.delayProgress >= task.delay then
			local progress = task.progress
			if progress == 0 then
				task.effect:start()
			end

			local shapeList = task.shapeList
			local count = #shapeList

			if progress > 0 and progress < 1 and count > 1 then
				local scaled = progress / task.span
				local b = floor( scaled ) + 2
				if b > count then
					b = count
				end
				local a = b - 1
				local t = scaled - ( a - 1 )
				if t > 1 then
					t = 1
				end

				local nodeA = shapeList[a]
				local nodeB = shapeList[b]
				local shapeA = nodeA
				local shapeB = nodeB
				if type( nodeA ) ~= "Shape" then
					shapeA = nodeA.shape
				end
				if type( nodeB ) ~= "Shape" then
					shapeB = nodeB.shape
				end

				if sm.exists( shapeA ) and sm.exists( shapeB ) then
					local positionA = nodeA:getWorldPosition()
					local positionB = nodeB:getWorldPosition()
					task.effect:setPosition( sm.vec3.new(
						positionA.x + ( positionB.x - positionA.x ) * t,
						positionA.y + ( positionB.y - positionA.y ) * t,
						positionA.z + ( positionB.z - positionA.z ) * t
					) )
				else
					progress = 1 -- End the effect
				end
			end

			progress = progress + dt / task.duration
			task.progress = progress

			if progress >= 1 then
				task.effect:stop()
				local lastIndex = #effectTasks
				if index ~= lastIndex then
					effectTasks[index] = effectTasks[lastIndex]
				end
				effectTasks[lastIndex] = nil
			end
		end

		task.delayProgress = task.delayProgress + dt
	end
end