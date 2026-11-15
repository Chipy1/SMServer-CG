SMMetrics = class()
SMMetrics.isSaveObject = true

G_SMSERVER_JSON_MESSAGE = G_SMSERVER_JSON_MESSAGE or {}

local msg = G_SMSERVER_JSON_MESSAGE
local scriptableObject = sm.storage.load("__SMM_SOB__")

local TPS_WINDOW = 20
local METRICS_PATH = "$CONTENT_DATA/pipe/metrics"

local lastTime = 0
local tickTimes = {}
local tickIndex = 1

local startedEpoch = 0
local tickCount = 0
local sessions = {}

-- Reusable metric tables.
msg.version = 1
msg.tps = msg.tps or 0
msg.online = false

msg.players = msg.players or {}

msg.server = msg.server or {}
local server = msg.server
local players = msg.players

local function isoTime(epoch)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local function updatePlayers(now)
    local playerList = sm.player.getAllPlayers()
    local count = 0

    for _, player in ipairs(playerList) do
        count = count + 1

        local id = player.id
        local session = sessions[id]

        if not session then
            session = now
            sessions[id] = session
        end

        local entry = players[count]

        if not entry then
            entry = {}
            players[count] = entry
        end

        entry.id = id
        entry.name = tostring(player.name or ("player-" .. tostring(id)))
        entry.time_playing = math.max(0, now - session)
    end

    -- Remove entries for players no longer online.
    for i = #players, count + 1, -1 do
        players[i] = nil
    end

    -- Remove sessions for players no longer online.
    for id in pairs(sessions) do
        local found = false

        for _, player in ipairs(playerList) do
            if player.id == id then
                found = true
                break
            end
        end

        if not found then
            sessions[id] = nil
        end
    end
end

local function writeMetrics(online)
    local now = os.time()

    msg.online = online

    updatePlayers(now)

    server.session_seconds = math.max(0, now - startedEpoch)
    server.started_epoch = startedEpoch
    server.started_at = isoTime(startedEpoch)

    msg.tick = tickCount
    msg.updated_at = isoTime(now)
    msg.updated_epoch = now

    sm.json.save(msg, METRICS_PATH)
end

function SMMetrics.server_onCreate(self)
    if scriptableObject and scriptableObject.id ~= self.scriptableObject.id then
        self.scriptableObject:destroy()
        return
    end

    if not scriptableObject then
        sm.storage.saveAndSync("__SMM_SOB__", self.scriptableObject)
    end

    lastTime = os.clock()
    tickTimes = {}
    tickIndex = 1

    startedEpoch = os.time()
    tickCount = 0

    msg.tps = 0

    writeMetrics(true)
end

function SMMetrics.server_onFixedUpdate(self, dt)
    tickCount = tickCount + 1

    local now = os.clock()
    local delta = now - lastTime

    lastTime = now

    tickTimes[tickIndex] = delta
    tickIndex = tickIndex % TPS_WINDOW + 1

    if #tickTimes == TPS_WINDOW then
        local totalTime = 0

        for i = 1, TPS_WINDOW do
            totalTime = totalTime + tickTimes[i]
        end

        if totalTime > 0 then
            msg.tps = TPS_WINDOW / totalTime
        end
    end
end

function SMMetrics.server_onReceiveUpdate(self)
    writeMetrics(true)
    print(msg)
end

function SMMetrics.server_onUnload(self)
    writeMetrics(false)
end
