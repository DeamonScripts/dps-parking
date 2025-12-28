--[[
    DPS-Parking - Delivery Module (Server)
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Vehicle delivery service with:
    - VIP tier verification
    - Full vehicle state restoration
    - Street spawn location (avoids clipping)
    - Optional NPC driver immersion
]]

Delivery = {}

local playerDeliveryCount = {}

-- ============================================
-- VIP TIER SYSTEM
-- ============================================

-- VIP tiers determine delivery benefits
Delivery.Tiers = {
    ['none'] = {
        enabled = true,
        maxPerHour = 2,
        discount = 0,
        rushAvailable = false,
        npcDriver = false,
        priorityMinutes = 0,
    },
    ['bronze'] = {
        enabled = true,
        maxPerHour = 3,
        discount = 0.10,  -- 10% off
        rushAvailable = true,
        npcDriver = false,
        priorityMinutes = 1,
    },
    ['silver'] = {
        enabled = true,
        maxPerHour = 5,
        discount = 0.20,  -- 20% off
        rushAvailable = true,
        npcDriver = true,
        priorityMinutes = 2,
    },
    ['gold'] = {
        enabled = true,
        maxPerHour = 10,
        discount = 0.35,  -- 35% off
        rushAvailable = true,
        npcDriver = true,
        priorityMinutes = 3,
    },
    ['platinum'] = {
        enabled = true,
        maxPerHour = -1,  -- Unlimited
        discount = 0.50,  -- 50% off
        rushAvailable = true,
        npcDriver = true,
        priorityMinutes = 5,
    },
}

---Get player's VIP tier
---@param citizenid string
---@return string tier
---@return table tierData
function Delivery.GetPlayerTier(citizenid)
    local vipData = State.GetVipPlayer(citizenid)

    if not vipData then
        return 'none', Delivery.Tiers['none']
    end

    local tier = vipData.tier or 'bronze'
    local tierData = Delivery.Tiers[tier] or Delivery.Tiers['bronze']

    return tier, tierData
end

-- ============================================
-- STREET SPAWN LOCATION FINDER
-- ============================================

-- Pre-defined delivery spawn offsets (relative to player)
-- These find nearby street-safe locations
local spawnOffsets = {
    vector3(8.0, 0.0, 0.0),
    vector3(-8.0, 0.0, 0.0),
    vector3(0.0, 8.0, 0.0),
    vector3(0.0, -8.0, 0.0),
    vector3(10.0, 5.0, 0.0),
    vector3(-10.0, 5.0, 0.0),
    vector3(10.0, -5.0, 0.0),
    vector3(-10.0, -5.0, 0.0),
    vector3(15.0, 0.0, 0.0),
    vector3(-15.0, 0.0, 0.0),
}

---Find a safe street spawn location near coordinates
---@param baseCoords vector3
---@param heading number
---@return vector4|nil spawnLocation
function Delivery.FindStreetSpawn(baseCoords, heading)
    -- Server can't do raycasts, so we calculate offset positions
    -- Client will verify and adjust on spawn

    local rad = math.rad(heading)
    local bestOffset = spawnOffsets[1]

    -- Try to find an offset that's roughly parallel to player heading (street direction)
    local forwardX = -math.sin(rad) * 12.0
    local forwardY = math.cos(rad) * 12.0

    return vector4(
        baseCoords.x + forwardX,
        baseCoords.y + forwardY,
        baseCoords.z,
        heading + 180.0  -- Face towards player
    )
end

-- ============================================
-- DELIVERY OPERATIONS
-- ============================================

---Request vehicle delivery
---@param source number
---@param plate string
---@param coords table {x, y, z, h}
---@param options table {rush, withDriver}
---@return boolean success
---@return string message
function Delivery.Request(source, plate, coords, options)
    options = options or {}

    if not Config.Delivery.enabled then
        return false, 'Delivery service disabled'
    end

    local citizenid = Bridge.GetCitizenId(source)
    if not citizenid then
        return false, L('error')
    end

    -- Get VIP tier
    local tier, tierData = Delivery.GetPlayerTier(citizenid)

    -- Check if delivery is enabled for this tier
    if not tierData.enabled then
        return false, 'Delivery not available for your membership tier'
    end

    -- Check if vehicle is parked
    local parkedVehicle = State.GetParkedVehicle(plate)
    if not parkedVehicle then
        return false, L('vehicle_not_parked')
    end

    -- Check ownership
    if parkedVehicle.citizenid ~= citizenid then
        return false, L('not_owner')
    end

    -- Check hourly limits (VIP tier based)
    local hourKey = citizenid .. '_' .. os.date('%Y%m%d%H')
    playerDeliveryCount[hourKey] = playerDeliveryCount[hourKey] or 0

    local maxPerHour = tierData.maxPerHour
    if maxPerHour > 0 and playerDeliveryCount[hourKey] >= maxPerHour then
        return false, L('delivery_max_reached')
    end

    -- Check rush availability
    local rush = options.rush or false
    if rush and not tierData.rushAvailable then
        rush = false  -- Downgrade to standard if rush not available for tier
    end

    -- Check NPC driver availability
    local withDriver = options.withDriver or false
    if withDriver and not tierData.npcDriver then
        withDriver = false  -- Not available for this tier
    end

    -- Calculate cost
    local baseCost = Config.Delivery.baseCost or 500
    local deliveryTime = Config.Delivery.standardTime or 5  -- minutes

    if rush then
        baseCost = math.ceil(baseCost * (Config.Delivery.rushMultiplier or 2.0))
        deliveryTime = Config.Delivery.rushTime or 2
    end

    -- Apply VIP discount
    if tierData.discount > 0 then
        baseCost = math.ceil(baseCost * (1 - tierData.discount))
    end

    -- Apply job discounts
    local playerJob = Bridge.GetPlayerJob(source)
    if playerJob and Config.Delivery.discounts and Config.Delivery.discounts[playerJob] then
        local jobDiscount = Config.Delivery.discounts[playerJob]
        baseCost = math.ceil(baseCost * (1 - jobDiscount))
    end

    -- Apply VIP priority time reduction
    if tierData.priorityMinutes > 0 then
        deliveryTime = math.max(1, deliveryTime - tierData.priorityMinutes)
    end

    -- Charge player
    local paid = false
    if Bridge.GetMoney(source, 'bank') >= baseCost then
        paid = Bridge.RemoveMoney(source, 'bank', baseCost, 'Vehicle delivery')
    elseif Bridge.GetMoney(source, 'cash') >= baseCost then
        paid = Bridge.RemoveMoney(source, 'cash', baseCost, 'Vehicle delivery')
    end

    if not paid then
        return false, L('insufficient_funds', Utils.FormatMoney(baseCost))
    end

    -- Find street spawn location
    local baseCoords = vector3(coords.x, coords.y, coords.z)
    local spawnLocation = Delivery.FindStreetSpawn(baseCoords, coords.h or 0.0)

    -- Create delivery record
    local deliveryId = citizenid .. '_' .. plate .. '_' .. os.time()
    local arrivalTime = os.time() + (deliveryTime * 60)

    State.SetDelivery(deliveryId, {
        id = deliveryId,
        citizenid = citizenid,
        plate = plate,
        vehicleData = parkedVehicle,  -- Store full vehicle state
        destination = spawnLocation,
        playerCoords = coords,
        requestedAt = os.time(),
        arrivalTime = arrivalTime,
        rush = rush,
        withDriver = withDriver,
        cost = baseCost,
        tier = tier,
    })

    playerDeliveryCount[hourKey] = playerDeliveryCount[hourKey] + 1

    -- Publish delivery requested event
    EventBus.Publish('delivery:requested', {
        deliveryId = deliveryId,
        citizenid = citizenid,
        plate = plate,
        tier = tier,
        rush = rush,
        withDriver = withDriver,
    })

    -- Schedule delivery completion
    SetTimeout(deliveryTime * 60 * 1000, function()
        Delivery.Complete(deliveryId)
    end)

    -- Notify with ETA
    local etaMsg = rush and 'Rush delivery' or 'Standard delivery'
    return true, ('%s arriving in %d minute(s) - %s'):format(
        etaMsg,
        deliveryTime,
        Utils.FormatMoney(baseCost)
    )
end

---Complete a delivery (spawn vehicle with full state)
---@param deliveryId string
function Delivery.Complete(deliveryId)
    local delivery = State.GetDelivery(deliveryId)
    if not delivery then return end

    local vehicleData = delivery.vehicleData
    if not vehicleData then
        Utils.Debug('Delivery.Complete: No vehicle data for ' .. deliveryId)
        State.RemoveDelivery(deliveryId)
        return
    end

    -- Check if player is online
    local player = Bridge.GetPlayerByCitizenId(delivery.citizenid)
    local playerSource = nil

    if player then
        playerSource = Bridge.IsESX() and player.source or player.PlayerData.source
    end

    -- Execute with hooks (allows extensions to modify delivery)
    local shouldContinue, hookData = EventBus.ExecutePreHooks('delivery:complete', {
        deliveryId = deliveryId,
        delivery = delivery,
        vehicleData = vehicleData,
        playerSource = playerSource,
    })

    if not shouldContinue then
        Utils.Debug('Delivery.Complete: Cancelled by pre-hook')
        return
    end

    -- Use hook-modified data if available
    delivery = hookData.delivery or delivery
    vehicleData = hookData.vehicleData or vehicleData

    -- Delete existing parked entity if it exists
    if vehicleData.entity and DoesEntityExist(vehicleData.entity) then
        DeleteEntity(vehicleData.entity)
    end

    -- Determine model
    local model = vehicleData.model or vehicleData.vehicle
    if not model then
        Utils.Debug('Delivery.Complete: No model for ' .. delivery.plate)
        State.RemoveDelivery(deliveryId)
        return
    end

    local modelHash = type(model) == 'string' and GetHashKey(model) or model

    -- Spawn at street location
    local dest = delivery.destination
    local vehicle = CreateVehicleServerSetter(
        modelHash,
        'automobile',
        dest.x, dest.y, dest.z,
        dest.w or dest.h or 0.0
    )

    Wait(500)

    if not DoesEntityExist(vehicle) then
        Utils.Debug('Delivery.Complete: Failed to spawn vehicle')
        -- Refund player
        if playerSource then
            Bridge.AddMoney(playerSource, 'bank', delivery.cost, 'Delivery failed - refund')
            Bridge.Notify(playerSource, 'Delivery failed - you have been refunded', 'error')
        end
        State.RemoveDelivery(deliveryId)
        return
    end

    -- Set plate
    SetVehicleNumberPlateText(vehicle, delivery.plate)

    local netId = NetworkGetNetworkIdFromEntity(vehicle)

    -- Update database - mark vehicle as out
    Bridge.DB.SetVehicleOut(delivery.plate)

    -- Remove from parked state
    State.RemoveParkedVehicle(delivery.plate)

    -- Notify client to restore vehicle state and optionally spawn NPC driver
    if playerSource then
        TriggerClientEvent('dps-parking:client:deliveryArrived', playerSource, {
            plate = delivery.plate,
            netId = netId,
            vehicleData = vehicleData,  -- Full state for restoration
            withDriver = delivery.withDriver,
            destination = delivery.destination,
        })

        Bridge.Notify(playerSource, L('delivery_arrived'), 'success')
    end

    -- Execute post-hooks
    EventBus.ExecutePostHooks('delivery:complete', {
        deliveryId = deliveryId,
        delivery = delivery,
        vehicle = vehicle,
        netId = netId,
        playerSource = playerSource,
    })

    -- Log to audit
    if DB and DB.AuditLog then
        DB.AuditLog('delivery_complete', delivery.citizenid, delivery.plate, {
            cost = delivery.cost,
            tier = delivery.tier,
            rush = delivery.rush,
            withDriver = delivery.withDriver,
        })
    end

    State.RemoveDelivery(deliveryId)

    Utils.Debug(('Delivery completed: %s -> %s'):format(delivery.plate, delivery.citizenid))
end

---Cancel a pending delivery
---@param source number
---@param deliveryId string
---@return boolean success
---@return string message
function Delivery.Cancel(source, deliveryId)
    local citizenid = Bridge.GetCitizenId(source)
    local delivery = State.GetDelivery(deliveryId)

    if not delivery then
        return false, 'Delivery not found'
    end

    if delivery.citizenid ~= citizenid then
        return false, 'Not your delivery'
    end

    -- Check if already in progress (last 30 seconds)
    local timeUntilArrival = delivery.arrivalTime - os.time()
    if timeUntilArrival < 30 then
        return false, 'Delivery is arriving - too late to cancel'
    end

    -- Partial refund (75%)
    local refund = math.floor(delivery.cost * 0.75)
    Bridge.AddMoney(source, 'bank', refund, 'Delivery cancelled - partial refund')

    State.RemoveDelivery(deliveryId)

    EventBus.Publish('delivery:cancelled', {
        deliveryId = deliveryId,
        citizenid = citizenid,
        refund = refund,
    })

    return true, ('Delivery cancelled - refunded %s'):format(Utils.FormatMoney(refund))
end

---Get player's active deliveries
---@param source number
---@return table deliveries
function Delivery.GetActive(source)
    local citizenid = Bridge.GetCitizenId(source)
    if not citizenid then return {} end

    local deliveries = State.GetPlayerDeliveries(citizenid)
    local result = {}

    for id, delivery in pairs(deliveries) do
        local timeLeft = delivery.arrivalTime - os.time()
        table.insert(result, {
            id = id,
            plate = delivery.plate,
            timeLeft = math.max(0, timeLeft),
            rush = delivery.rush,
            withDriver = delivery.withDriver,
        })
    end

    return result
end

-- ============================================
-- EVENTS
-- ============================================

RegisterNetEvent('dps-parking:server:requestDelivery', function(plate, coords, options)
    local source = source
    local success, message = Delivery.Request(source, plate, coords, options)
    Bridge.Notify(source, message, success and 'success' or 'error')
end)

RegisterNetEvent('dps-parking:server:cancelDelivery', function(deliveryId)
    local source = source
    local success, message = Delivery.Cancel(source, deliveryId)
    Bridge.Notify(source, message, success and 'success' or 'error')
end)

-- Callback for active deliveries
Bridge.CreateCallback('dps-parking:server:getActiveDeliveries', function(source, cb)
    cb(Delivery.GetActive(source))
end)

-- ============================================
-- EVENTBUS SUBSCRIPTION
-- ============================================

-- Subscribe to parking events for delivery integration
EventBus.Subscribe('parking:unpark', function(data)
    -- Cancel any pending deliveries for this vehicle
    local citizenid = data.citizenid
    local plate = data.plate

    for deliveryId, delivery in pairs(State._data.activeDeliveries) do
        if delivery.plate == plate and delivery.citizenid == citizenid then
            State.RemoveDelivery(deliveryId)
            Utils.Debug(('Cancelled delivery %s - vehicle unparked manually'):format(deliveryId))
        end
    end
end, EventBus.Priority.HIGH)

print('^2[DPS-Parking] Delivery module (server) loaded^0')

return Delivery
