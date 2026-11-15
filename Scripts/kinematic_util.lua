dofile( "$CONTENT_DATA/Scripts/game/survival_constants.lua" )
dofile( "$CONTENT_DATA/Scripts/util.lua" )

local TimeStep = 0.025

function EvaluateNodes( trackParamData, position, rotation, scale )
	local trackSettings = {}
	if not trackParamData then
		return nil, trackSettings
	end


	-- Translate track nodes into world space
	local worldTrackList = {}
	local trackIndex = 1
	local worldPosition = position
	local worldRotation = rotation

	local paramTrackNodes = nil
	if trackParamData.file and trackParamData.file ~= "" then
		paramTrackNodes = sm.json.open( trackParamData.file ).track
		assert( paramTrackNodes, "Opening track file failed!" )
	elseif trackParamData.track then
		paramTrackNodes = trackParamData.track
	end

	if paramTrackNodes then
		worldTrackList[trackIndex] = {}
		for i, trackNode in ipairs( paramTrackNodes ) do
			local trackPos = Vec3IfArray( trackNode.position )
			local trackRotEuler = Vec3IfArray( trackNode.rotation )
			local trackRotQuat = sm.quat.fromEuler( trackRotEuler )

			local worldTrackNode = {}
			worldTrackNode.position = worldPosition + worldRotation * ( trackPos * scale )
			worldTrackNode.rotation = worldRotation * trackRotQuat
			if trackNode.durationFromSpeed then
				worldTrackNode.speed = trackNode.speed
			else
				worldTrackNode.duration = trackNode.duration
			end
			if trackNode.inheritDuration then
				-- Overwrite duration/speed with the values from the previous node if possible
				local previousNode = worldTrackList[trackIndex][#worldTrackList[trackIndex]]
				if previousNode then
					worldTrackNode.duration = worldTrackList[trackIndex][#worldTrackList[trackIndex]].duration
					worldTrackNode.speed = worldTrackList[trackIndex][#worldTrackList[trackIndex]].speed
				end
			end
			worldTrackNode.easing = trackNode.easing
			if trackNode.event and trackNode.event ~= "" then
				worldTrackNode.event = trackNode.event
			end
			if trackNode.eventDelay and trackNode.eventDelay ~= 0.0 then
				worldTrackNode.eventDelay = trackNode.eventDelay
			end
			worldTrackNode.delay = trackNode.delay
			if trackNode.forwardsEvent ~= nil then
				worldTrackNode.forwardsEvent = trackNode.forwardsEvent
			end

			if trackNode.backwardsEvent ~= nil then
				worldTrackNode.backwardsEvent = trackNode.backwardsEvent
			end

			if trackNode.effects and not IsEmptyTable( trackNode.effects ) then
				worldTrackNode.effects = trackNode.effects
			end

			if trackNode.attachedEffects and not IsEmptyTable( trackNode.attachedEffects ) then
				worldTrackNode.attachedEffects = trackNode.attachedEffects
			end

			-- merge deprecated attached effect into the attached effects list.
			if trackNode.attachedEffect ~= nil and trackNode.attachedEffect ~= "" then
				if worldTrackNode.attachedEffects == nil then
					worldTrackNode.attachedEffects = {}
				end
				table.insert( worldTrackNode.attachedEffects, { effectName = trackNode.attachedEffect } )
			end

			if trackNode.deactivateEffects ~= nil then
				worldTrackNode.deactivateEffects = trackNode.deactivateEffects
			end

			if trackNode.kinematicActivations ~= nil then
				worldTrackNode.kinematicActivations = trackNode.kinematicActivations
			end

			local worldTangents = {}
			if trackNode.tangents then
				for _, tangent in ipairs( trackNode.tangents ) do
					local tangentPos = Vec3IfArray( tangent.position )
					local tangentRotEuler = Vec3IfArray( tangent.rotation )
					local tangentRotQuat = sm.quat.fromEuler( tangentRotEuler )

					local worldTangent = {}
					worldTangent.position = worldPosition + worldRotation * ( tangentPos * scale )
					worldTangent.rotation = worldRotation * tangentRotQuat
					worldTangents[#worldTangents+1] = worldTangent
				end
			end
			worldTrackNode.tangents = worldTangents

			worldTrackList[trackIndex][#worldTrackList[trackIndex]+1] = worldTrackNode

			worldTrackNode.stop = trackNode.stop
			if trackNode.stop then
				trackIndex = trackIndex + 1
				worldTrackList[trackIndex] = {}
				worldTrackList[trackIndex][#worldTrackList[trackIndex]+1] = worldTrackNode
			end

		end
	end

	local trackDataList = {}
	for _, nodes in ipairs( worldTrackList ) do
		-- Extract segment information
		local distances = {}
		local durations = {}
		local easings = {}
		local segments = {}
		if nodes and #nodes > 1 then
			for i = 1, #nodes-1 do
				local points = {}
				local rotations = {}
				points[#points+1] = nodes[i].position
				rotations[#rotations+1] = nodes[i].rotation
				for _, tangent in ipairs( nodes[i].tangents ) do
					points[#points+1] = tangent.position
					rotations[#rotations+1] = tangent.rotation
				end
				points[#points+1] = nodes[i+1].position
				rotations[#rotations+1] = nodes[i+1].rotation

				segments[#segments+1] = { points = points, rotations = rotations }
			end

			-- Used for progress calculation
			distances[1] = 0
			for _, segment in ipairs( segments ) do
				local length
				local pointCount = #segment.points
				if pointCount > 2 then
					length = EstimateBezierLength( segment.points, 32 )
				elseif pointCount == 2 then
					length = sm.vec3.getDistance( segment.points[2], segment.points[1] )
				else
					length = 0
				end
				distances[#distances+1] = distances[#distances] + length
			end

			durations[1] = 0
			for i = 1, #nodes - 1 do
				local delay = nodes[i].delay or 0.0
				if nodes[i].duration then
					durations[#durations+1] = durations[#durations] + nodes[i].duration + delay
				elseif nodes[i].speed then
					local distanceSegment = distances[i+1] - distances[i]
					local durationFromSpeed = distanceSegment / math.max( nodes[i].speed, FLT_EPSILON )
					durations[#durations+1] = durations[#durations] + durationFromSpeed + delay
				end
				easings[#easings+1] = nodes[i].easing
			end

			local finalDelay = nodes[#nodes].delay or 0.0
			durations[#durations] = durations[#durations] + finalDelay

			local trackData = {}
			trackData.nodes = nodes
			trackData.durations = durations
			trackData.easings = easings
			trackData.distances = distances
			trackData.segments = segments

			trackDataList[#trackDataList+1] = trackData
		end
	end

	if trackParamData then
		trackSettings.loop = trackParamData.loop
	end

	return trackDataList, trackSettings
end

function GetKinematicTransform( time, trackData )
	local transform
	local segmentProgressData
	local segmentIndex = BinarySearchInterval( trackData.durations, time )
	if segmentIndex then
		segmentIndex =  math.min( math.max( segmentIndex, 1 ), #trackData.segments )
		local fromTime = trackData.durations[segmentIndex]
		local toTime = trackData.durations[segmentIndex+1]
		local easing = trackData.easings[segmentIndex]

		local delay = trackData.nodes[segmentIndex].delay or 0
		local delayedTime = time - delay
		local delayedToTime = toTime - delay

		local finalDelay = trackData.nodes[#trackData.nodes].delay or 0
		if segmentIndex == #trackData.segments then
			delayedToTime = delayedToTime - finalDelay
		end

		local segmentProgress = ( delayedTime - fromTime ) / ( delayedToTime - fromTime )
		segmentProgress = finite( segmentProgress ) and segmentProgress or 1.0
		segmentProgress = math.min( math.max( segmentProgress, 0.0 ), 1.0 )
		segmentProgress = sm.util.easing( easing, segmentProgress )

		local kinematicPosition = BezierPosition( trackData.segments[segmentIndex].points, segmentProgress )
		local kinematicRotation = BezierRotation( trackData.segments[segmentIndex].rotations, segmentProgress )

		transform = { worldPosition = kinematicPosition, worldRotation = kinematicRotation }
		segmentProgressData = { segmentIndex = segmentIndex, segmentProgress = segmentProgress }
	end
	return transform, segmentProgressData
end

function KinematicTrackUpdate( trackDataList, trackSettings, updateData, currentTick )
	local trackIndex = updateData.trackIndex
	local playForward = updateData.playForward
	local tick = updateData.tick
	local moving = updateData.moving
	local segmentProgressData = { segmentIndex = 1, segmentProgress = 0.0 }
	local transform = nil

	local elapsedTicks = 0
	if tick then
		local estimatedServerTick = currentTick or sm.game.getServerTick()
		elapsedTicks = math.max( estimatedServerTick - tick, 0 )
	end
	local time = elapsedTicks * TimeStep

	local trackData = trackDataList[trackIndex]
	if trackData and trackData.segments and #trackData.segments >= 1 then

		-- Adjust time when moving backwards
		local arrivalTime = trackData.durations[#trackData.durations]
		if not playForward then
			time = arrivalTime - time
		end

		-- Check if arrived at the end of the current track
		if playForward and time >= arrivalTime then
			moving = false
			local nextTrackIndex = ( trackIndex % #trackDataList ) + 1

			if not trackSettings.loop and nextTrackIndex <= trackIndex then
				-- Change direction
				playForward = not playForward
			else
				-- Switching track, position at the start of the next track
				trackIndex = nextTrackIndex
				trackData = trackDataList[trackIndex]
				time = 0
			end
		elseif not playForward and time <= 0 then
			moving = false
			local nextTrackIndex = ( ( trackIndex - 2 ) % #trackDataList ) + 1

			if not trackSettings.loop and nextTrackIndex >= trackIndex then
				-- Change direction
				playForward = not playForward
			else
				-- Switching track, position at the start of the next track
				trackIndex = nextTrackIndex
				trackData = trackDataList[trackIndex]
				time = trackData.durations[#trackData.durations]
			end
		end

		-- Find placement on the current segment
		
		transform, segmentProgressData = GetKinematicTransform( time, trackData )
	else
		-- No track found
		moving = false
	end
	updateData.trackIndex = trackIndex
	updateData.playForward = playForward
	updateData.tick = tick
	updateData.moving = moving
	return updateData, segmentProgressData, transform
end

function ApplyTransform( currentTransform, applyTransform, weight, initialPosition, initialRotation )
	local localPosition = applyTransform.worldPosition - initialPosition
	local localRotation = sm.quat.inverse(initialRotation) * applyTransform.worldRotation
	if not currentTransform then
		if weight == 1 then
			currentTransform = { 
				worldPosition = sm.vec3.new( applyTransform.worldPosition ),
				worldRotation = sm.quat.new( applyTransform.worldRotation )
			}
		else
			currentTransform = {
				worldPosition = initialPosition + ( localPosition * weight ),
				worldRotation = initialRotation * sm.quat.slerp( sm.quat.identity(), localRotation, weight )
			}
		end
	else
		if weight == 1 then
			currentTransform.worldPosition = currentTransform.worldPosition + localPosition
			currentTransform.worldRotation = currentTransform.worldRotation * localRotation
		else
			currentTransform.worldPosition = currentTransform.worldPosition + ( localPosition * weight )
			currentTransform.worldRotation = currentTransform.worldRotation * sm.quat.slerp( sm.quat.identity(), localRotation, weight )
		end
	end
	return currentTransform
end

-- Tracks are blended in name order so the server, clients and terrain scripts agree. Rotations do not commute, so pairs() order would not be enough.
function SortedTrackNames( tracks )
	local names = {}
	for trackName, _ in pairs( tracks ) do
		names[#names + 1] = trackName
	end
	table.sort( names )
	return names
end

-- The state a track resumes from when its kinematic loads. Shared by Kinematic.server_onCreate and the terrain scripts so both place the kinematic identically.
-- A clean unload ( stored.unloaded ) pauses a track from the unload tick. A record from an earlier session without one ( a crash ) pauses it from lastSessionTick, the last saved game tick, so the time before it loads in this session does not count. A record written this session without one keeps its absolute tick.
-- A pending persistent activation starts the track when the kinematic loads, never earlier. A kinematic that does not save its state has no record of consuming it, so the activation starts the track on every load.
-- Returns nil when there is nothing stored or pending for the track.
function ResolveStoredTrackState( stored, trackName, activation, currentTick, lastSessionTick )
	local storedTrack = stored and stored.tracks and stored.tracks[trackName]
	local state = nil
	if storedTrack then
		state = {}
		for key, value in pairs( storedTrack ) do
			state[key] = value
		end
		-- unloadTick is the tick of the record's last store, unload or not ( see Kinematic.sv_store ).
		local pausedSince = nil
		if stored.unloaded then
			pausedSince = stored.unloadTick
		elseif stored.unloadTick and stored.unloadTick <= lastSessionTick then
			pausedSince = lastSessionTick
		end
		if state.tick and pausedSince then
			state.tick = state.tick + ( currentTick - pausedSince )
		end
	end

	if activation and activation.tick and ( activation.trackName or "track" ) == trackName then
		-- Determine if the activation should be applied based on the stored unloadTick and the activation tick, unloadTick is the tick of the record's last store...
		-- same rule as Kinematic.sv_activate: a moving track ignores activation
		if ( stored == nil or stored.unloadTick == nil or activation.tick > stored.unloadTick ) and not ( state and state.moving ) then
			state = state or {}
			state.moving = true
			state.tick = currentTick
		end
	end
	return state
end

function LoadKinematicFromStorage( kinematic, storageData, worldPosition, currentTick, world, cellX, cellY )
	if storageData then
		local storageKey = nil
		if kinematic.params and kinematic.params.storageTag and kinematic.params.storageTag ~= "" then
			storageKey = kinematic.params.storageTag
		else
			cellX = cellX or 0
			cellY = cellY or 0
			local offsetPosition = kinematic.pos + sm.vec3.new( cellX * CELL_SIZE, cellY * CELL_SIZE, 0 )
			storageKey = sm.terrainHarvestable.calculateInitialHash( kinematic.uuid, world, offsetPosition, kinematic.rot )
		end

		local stored = nil
		if storageData[KINEMATIC_STORAGE_TABLE] then
			stored = storageData[KINEMATIC_STORAGE_TABLE][storageKey]
		end

		local activation = nil
		if storageData[KINEMATIC_EVENTTRIGGER_TABLE] and kinematic.params and kinematic.params.eventListen then
			activation = storageData[KINEMATIC_EVENTTRIGGER_TABLE][kinematic.params.eventListen]
		end

		-- Blend the tracks the same way Kinematic.server_onFixedUpdate does, so the kinematic is created where its first update expects it.
		local finalTransform = nil
		if kinematic.params and kinematic.params.track then
			for _, trackName in ipairs( SortedTrackNames( kinematic.params.track ) ) do
				local trackParamData = kinematic.params.track[trackName]
				local state = ResolveStoredTrackState( stored, trackName, activation, currentTick, sm.terrainGeneration.getLastSessionTick() )
				local weight = state and state.weight or 1
				if state and weight > 0 then
					local transform = nil
					if state.moving then
						local trackDataList, trackSettings = EvaluateNodes( trackParamData, worldPosition, kinematic.rot, kinematic.scale )
						local updateData = {
							moving = true,
							playForward = state.playForward ~= false,
							trackIndex = state.trackIndex or 1,
							tick = state.tick or currentTick,
							weight = weight
						}
						local _, _, trackTransform = KinematicTrackUpdate( trackDataList, trackSettings, updateData, currentTick )
						transform = trackTransform
					else
						transform = state.lastTransform
					end
					if transform then
						finalTransform = ApplyTransform( finalTransform, transform, weight, worldPosition, kinematic.rot )
					end
				end
			end
		end

		if finalTransform then
			kinematic.storedPos = finalTransform.worldPosition
			kinematic.storedRot = finalTransform.worldRotation
		elseif stored then
			if stored.position then
				kinematic.storedPos = stored.position
			end
			if stored.rotation then
				kinematic.storedRot = stored.rotation
			end
		end
	end
end
