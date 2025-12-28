--[[
    DPS-Parking - Valet Service Module (Server)
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Valet NPCs that park and retrieve vehicles:
    - Multiple valet locations
    - Queue system with VIP priority
    - Tip system for faster service
    - Integration with parking StateManager
]]

Valet = {}

-- Active valet sessions
Valet._sessions = {}      -- sessionId -> session data
Valet._queues = {}        -- locationId -> queue array
Valet._parkedByValet = {} -- plate -> valet parking data

-- ============================================
-- CONFIGURATION
-- ============================================

Valet.Config = {
    basePrice = 100,           -- Base valet fee
    retrievalPrice = 50,       -- Fee to retrieve
    tipMultipliers = {         -- Tip levels affect wait time
        none = 1.0,
        small = 0.75,          -- 25% faster
        medium = 0.5,          -- 50% faster
        large = 0.25,          -- 75% faster
    },
    baseParkTime = 30,         -- Seconds to park
    baseRetrieveTime = 45,     -- Seconds to retrieve
    vipPriorityBonus = 0.5,    -- VIPs get 50% time reduction
    maxQueuePerLocation = 10,  -- Max vehicles in queue
}

-- ============================================
-- VALET LOCATIONS
-- ============================================

-- Locations are loaded from Config.Valet.locations
-- Each location has: id, name, coords, parkingSpots[], npcModel, blip

---Get valet location by ID
---@param locationId string
---@return table|nil
function Valet.GetLocation(locationId)
    if not Config.Valet or not Config.Valet.locations then
        return nil
    end

    for _, loc in ipairs(Config.Valet.locations) do
        if loc.id == locationId then
            return loc
        end
    end
    return nil
end

---Get all valet locations
---@return table
function Valet.GetLocations()
    return Config.Valet and Config.Valet.locations or {}
end

-- ============================================
-- QUEUE MANAGEMENT
-- ============================================

---Add to valet queue
---@param locationId string
---@param sessionId string
---@param priority number (lower = higher priority)
local function AddToQueue(locationId, sessionId, priority)
    if not Valet._queues[locationId] then
        Valet._queues[locationId] = {}
    end

    table.insert(Valet._queues[locationId], {
        sessionId = sessionId,
        priority = priority,
        addedAt = os.time()
    })

    -- Sort by priority (VIPs first)
    table.sort(Valet._queues[locationId], function(a, b)
        return a.priority < b.priority
    end)
end

---Remove from queue
---@param locationId string
---@param sessionId string
local function RemoveFromQueue(locationId, sessionId)
    if not Valet._queues[locationId] then return end

    for i, item in ipairs(Valet._queues[locationId]) do
        if item.sessionId == sessionId then
            table.remove(Valet._queues[locationId], i)
            return
        end
    end
end

---Get queue position
---@param locationId string
---@param sessionId string
---@return number position (0 = not in queue)
function Valet.GetQueuePosition(locationId, sessionId)
    if not Valet._queues[locationId] then return 0 end

    for i, item in ipairs(Valet._queues[locationId]) do
        if item.sessionId == sessionId then
            return i
        end
    end
    return 0
end

-- ============================================
-- VALET OPERATIONS
-- ============================================

---Request valet to park vehicle
---@param source number
---@param locationId string
---@param vehicleNetId number
---@param tipLevel string (none/small/medium/large)
---@return boolean success
---@return string message
function Valet.ParkVehicle(source, locationId, vehicleNetId, tipLevel)
    if not Config.Valet or not Config.Valet.enabled then
        return false, 'Valet service is disabled'
    end

    local citizenid = Bridge.GetCitizenId(source)
    if not citizenid then
        return false, L('error')
    end

    local location = Valet.GetLocation(locationId)
    if not location then
        return false, 'Invalid valet location'
    end

    -- Check queue capacity
    local queueSize = Valet._queues[locationId] and #Valet._queues[locationId] or 0
    if queueSize >= Valet.Config.maxQueuePerLocation then
        return false, 'Valet queue is full - please try later'
    end

    -- Get vehicle info
    local vehicle = NetworkGetEntityFromNetworkId(vehicleNetId)
    if not DoesEntityExist(vehicle) then
        return false, 'Vehicle not found'
    end

    local plate = GetVehicleNumberPlateText(vehicle)

    -- Check ownership
    if not Bridge.DB.PlayerOwnsVehicle(citizenid, plate) then
        return false, L('not_owner')
    end

    -- Check if already parked by valet
    if Valet._parkedByValet[plate] then
        return false, 'Vehicle is already with valet'
    end

    -- Calculate cost
    tipLevel = tipLevel or 'none'
    local tipMultiplier = Valet.Config.tipMultipliers[tipLevel] or 1.0
    local baseCost = Valet.Config.basePrice

    local tipAmount = 0
    if tipLevel == 'small' then tipAmount = 50
    elseif tipLevel == 'medium' then tipAmount = 100
    elseif tipLevel == 'large' then tipAmount = 200
    end

    local totalCost = baseCost + tipAmount

    -- Charge player
    if Bridge.GetMoney(source, 'cash') >= totalCost then
        Bridge.RemoveMoney(source, 'cash', totalCost, 'Valet parking')
    elseif Bridge.GetMoney(source, 'bank') >= totalCost then
        Bridge.RemoveMoney(source, 'bank', totalCost, 'Valet parking')
    else
        return false, L('insufficient_funds', Utils.FormatMoney(totalCost))
    end

    -- Calculate wait time
    local waitTime = Valet.Config.baseParkTime * tipMultiplier

    -- VIP bonus
    if State.IsVip(citizenid) then
        waitTime = waitTime * Valet.Config.vipPriorityBonus
    end

    waitTime = math.max(5, math.floor(waitTime))

    -- Create session
    local sessionId = citizenid .. '_' .. plate .. '_' .. os.time()
    local priority = State.IsVip(citizenid) and 1 or 10

    Valet._sessions[sessionId] = {
        id = sessionId,
        type = 'park',
        citizenid = citizenid,
        plate = plate,
        vehicleNetId = vehicleNetId,
        locationId = locationId,
        tipLevel = tipLevel,
        cost = totalCost,
        startedAt = os.time(),
        completesAt = os.time() + waitTime,
    }

    AddToQueue(locationId, sessionId, priority)

    -- Notify client to start valet animation
    TriggerClientEvent('dps-parking:client:valetTakeVehicle', source, {
        sessionId = sessionId,
        plate = plate,
        waitTime = waitTime,
        locationId = locationId,
    })

    -- Schedule completion
    SetTimeout(waitTime * 1000, function()
        Valet.CompletePark(sessionId)
    end)

    EventBus.Publish('valet:parkRequested', {
        sessionId = sessionId,
        citizenid = citizenid,
        plate = plate,
        locationId = locationId,
    })

    return true, ('Valet is parking your vehicle - %d seconds'):format(waitTime)
end

---Complete parking operation
---@param sessionId string
function Valet.CompletePark(sessionId)
    local session = Valet._sessions[sessionId]
    if not session then return end

    -- Find available parking spot
    local location = Valet.GetLocation(session.locationId)
    if not location or not location.parkingSpots then
        Utils.Debug('Valet.CompletePark: No parking spots for location')
        return
    end

    local spotIndex = nil
    for i, spot in ipairs(location.parkingSpots) do
        if not spot.occupied then
            spotIndex = i
            spot.occupied = true
            spot.plate = session.plate
            break
        end
    end

    if not spotIndex then
        -- No spots available - refund
        local player = Bridge.GetPlayerByCitizenId(session.citizenid)
        if player then
            local playerSource = Bridge.IsESX() and player.source or player.PlayerData.source
            if playerSource then
                Bridge.AddMoney(playerSource, 'bank', session.cost, 'Valet refund - no spots')
                Bridge.Notify(playerSource, 'No parking spots available - refunded', 'error')
            end
        end
        Valet._sessions[sessionId] = nil
        RemoveFromQueue(session.locationId, sessionId)
        return
    end

    -- Store valet parking data
    Valet._parkedByValet[session.plate] = {
        plate = session.plate,
        citizenid = session.citizenid,
        locationId = session.locationId,
        spotIndex = spotIndex,
        parkedAt = os.time(),
        vehicleData = nil, -- Client will send this
    }

    -- Notify client to complete (delete vehicle, store data)
    local player = Bridge.GetPlayerByCitizenId(session.citizenid)
    if player then
        local playerSource = Bridge.IsESX() and player.source or player.PlayerData.source
        if playerSource then
            TriggerClientEvent('dps-parking:client:valetParkComplete', playerSource, {
                sessionId = sessionId,
                plate = session.plate,
                spotIndex = spotIndex,
            })
            Bridge.Notify(playerSource, 'Your vehicle has been parked by valet', 'success')
        end
    end

    RemoveFromQueue(session.locationId, sessionId)
    Valet._sessions[sessionId] = nil

    EventBus.Publish('valet:parkCompleted', {
        plate = session.plate,
        citizenid = session.citizenid,
        locationId = session.locationId,
        spotIndex = spotIndex,
    })
end

---Request valet to retrieve vehicle
---@param source number
---@param plate string
---@param tipLevel string
---@return boolean success
---@return string message
function Valet.RetrieveVehicle(source, plate, tipLevel)
    if not Config.Valet or not Config.Valet.enabled then
        return false, 'Valet service is disabled'
    end

    local citizenid = Bridge.GetCitizenId(source)
    if not citizenid then
        return false, L('error')
    end

    -- Check if vehicle is parked by valet
    local valetData = Valet._parkedByValet[plate]
    if not valetData then
        return false, 'Vehicle is not parked with valet'
    end

    -- Check ownership
    if valetData.citizenid ~= citizenid then
        return false, L('not_owner')
    end

    -- Calculate cost
    tipLevel = tipLevel or 'none'
    local tipMultiplier = Valet.Config.tipMultipliers[tipLevel] or 1.0
    local baseCost = Valet.Config.retrievalPrice

    local tipAmount = 0
    if tipLevel == 'small' then tipAmount = 25
    elseif tipLevel == 'medium' then tipAmount = 50
    elseif tipLevel == 'large' then tipAmount = 100
    end

    local totalCost = baseCost + tipAmount

    -- Charge player
    if Bridge.GetMoney(source, 'cash') >= totalCost then
        Bridge.RemoveMoney(source, 'cash', totalCost, 'Valet retrieval')
    elseif Bridge.GetMoney(source, 'bank') >= totalCost then
        Bridge.RemoveMoney(source, 'bank', totalCost, 'Valet retrieval')
    else
        return false, L('insufficient_funds', Utils.FormatMoney(totalCost))
    end

    -- Calculate wait time
    local waitTime = Valet.Config.baseRetrieveTime * tipMultiplier

    if State.IsVip(citizenid) then
        waitTime = waitTime * Valet.Config.vipPriorityBonus
    end

    waitTime = math.max(5, math.floor(waitTime))

    -- Create session
    local sessionId = citizenid .. '_' .. plate .. '_retrieve_' .. os.time()

    Valet._sessions[sessionId] = {
        id = sessionId,
        type = 'retrieve',
        citizenid = citizenid,
        plate = plate,
        locationId = valetData.locationId,
        tipLevel = tipLevel,
        cost = totalCost,
        vehicleData = valetData.vehicleData,
        startedAt = os.time(),
        completesAt = os.time() + waitTime,
    }

    -- Notify client
    TriggerClientEvent('dps-parking:client:valetRetrieving', source, {
        sessionId = sessionId,
        plate = plate,
        waitTime = waitTime,
    })

    -- Schedule completion
    SetTimeout(waitTime * 1000, function()
        Valet.CompleteRetrieval(sessionId)
    end)

    return true, ('Valet is retrieving your vehicle - %d seconds'):format(waitTime)
end

---Complete retrieval operation
---@param sessionId string
function Valet.CompleteRetrieval(sessionId)
    local session = Valet._sessions[sessionId]
    if not session then return end

    local location = Valet.GetLocation(session.locationId)
    if not location then return end

    -- Free up parking spot
    local valetData = Valet._parkedByValet[session.plate]
    if valetData and location.parkingSpots and location.parkingSpots[valetData.spotIndex] then
        location.parkingSpots[valetData.spotIndex].occupied = false
        location.parkingSpots[valetData.spotIndex].plate = nil
    end

    -- Notify client to spawn vehicle
    local player = Bridge.GetPlayerByCitizenId(session.citizenid)
    if player then
        local playerSource = Bridge.IsESX() and player.source or player.PlayerData.source
        if playerSource then
            TriggerClientEvent('dps-parking:client:valetDeliverVehicle', playerSource, {
                sessionId = sessionId,
                plate = session.plate,
                vehicleData = session.vehicleData,
                spawnPoint = location.retrievalPoint or location.coords,
            })
            Bridge.Notify(playerSource, 'Your vehicle has arrived', 'success')
        end
    end

    -- Cleanup
    Valet._parkedByValet[session.plate] = nil
    Valet._sessions[sessionId] = nil

    EventBus.Publish('valet:retrievalCompleted', {
        plate = session.plate,
        citizenid = session.citizenid,
        locationId = session.locationId,
    })
end

---Get player's vehicles parked with valet
---@param citizenid string
---@return table
function Valet.GetPlayerVehicles(citizenid)
    local vehicles = {}
    for plate, data in pairs(Valet._parkedByValet) do
        if data.citizenid == citizenid then
            table.insert(vehicles, {
                plate = plate,
                locationId = data.locationId,
                parkedAt = data.parkedAt,
            })
        end
    end
    return vehicles
end

-- ============================================
-- EVENTS
-- ============================================

RegisterNetEvent('dps-parking:server:valetPark', function(locationId, vehicleNetId, tipLevel)
    local source = source
    local success, message = Valet.ParkVehicle(source, locationId, vehicleNetId, tipLevel)
    Bridge.Notify(source, message, success and 'success' or 'error')
end)

RegisterNetEvent('dps-parking:server:valetRetrieve', function(plate, tipLevel)
    local source = source
    local success, message = Valet.RetrieveVehicle(source, plate, tipLevel)
    Bridge.Notify(source, message, success and 'success' or 'error')
end)

RegisterNetEvent('dps-parking:server:valetStoreData', function(plate, vehicleData)
    local source = source
    local citizenid = Bridge.GetCitizenId(source)

    if Valet._parkedByValet[plate] and Valet._parkedByValet[plate].citizenid == citizenid then
        Valet._parkedByValet[plate].vehicleData = vehicleData
    end
end)

-- Callback for player's valet vehicles
Bridge.CreateCallback('dps-parking:server:getValetVehicles', function(source, cb)
    local citizenid = Bridge.GetCitizenId(source)
    cb(Valet.GetPlayerVehicles(citizenid))
end)

print('^2[DPS-Parking] Valet module (server) loaded^0')

return Valet
