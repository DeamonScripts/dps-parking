--[[
    DPS-Parking - Delivery Module (Client)
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Client-side delivery with:
    - Full vehicle state restoration
    - Optional NPC driver immersion
    - Street-safe spawn verification
]]

local activeDeliveryBlips = {}

-- NPC Driver models (variety for immersion)
local driverModels = {
    'a_m_y_business_01',
    'a_m_y_business_02',
    'a_m_m_business_01',
    'a_f_y_business_01',
    's_m_m_valet_01',
}

-- ============================================
-- VEHICLE STATE RESTORATION
-- ============================================

---Restore full vehicle state from saved data
---@param vehicle number
---@param vehicleData table
local function RestoreVehicleState(vehicle, vehicleData)
    if not DoesEntityExist(vehicle) then return end

    -- Wait for vehicle to be ready
    local timeout = 50
    while not IsVehicleDriveable(vehicle) and timeout > 0 do
        Wait(100)
        timeout = timeout - 1
    end

    -- Restore mods using VehicleData utility if available
    if VehicleData and vehicleData.damage then
        VehicleData.Deserialize(vehicle, vehicleData)
    elseif vehicleData.mods then
        Bridge.SetVehicleProperties(vehicle, vehicleData.mods)
    end

    -- Restore fuel
    if vehicleData.fuel then
        Bridge.SetFuel(vehicle, vehicleData.fuel)
    end

    -- Restore extras
    if vehicleData.extras then
        for extraId, enabled in pairs(vehicleData.extras) do
            SetVehicleExtra(vehicle, tonumber(extraId), not enabled)
        end
    end

    -- Restore damage state if VehicleData isn't available
    if not VehicleData and vehicleData.damage then
        -- Windows
        if vehicleData.damage.windows then
            for i, intact in pairs(vehicleData.damage.windows) do
                if not intact then
                    SmashVehicleWindow(vehicle, tonumber(i))
                end
            end
        end

        -- Tyres
        if vehicleData.damage.tyres then
            for i, tyreData in pairs(vehicleData.damage.tyres) do
                if tyreData.burst or tyreData.completelyBurst then
                    SetVehicleTyreBurst(vehicle, tonumber(i), tyreData.completelyBurst, 1000.0)
                end
            end
        end

        -- Body/Engine health
        if vehicleData.damage.body then
            SetVehicleBodyHealth(vehicle, vehicleData.damage.body)
        end
        if vehicleData.damage.engine then
            SetVehicleEngineHealth(vehicle, vehicleData.damage.engine)
        end
    end

    Utils.Debug('Restored vehicle state for delivered vehicle')
end

-- ============================================
-- NPC DRIVER SYSTEM
-- ============================================

---Spawn NPC driver in vehicle
---@param vehicle number
---@param exitAfter boolean
---@return number|nil ped
local function SpawnNPCDriver(vehicle, exitAfter)
    if not DoesEntityExist(vehicle) then return nil end

    -- Pick random driver model
    local modelName = driverModels[math.random(#driverModels)]
    local modelHash = GetHashKey(modelName)

    -- Load model
    RequestModel(modelHash)
    local timeout = 50
    while not HasModelLoaded(modelHash) and timeout > 0 do
        Wait(100)
        timeout = timeout - 1
    end

    if not HasModelLoaded(modelHash) then
        Utils.Debug('Failed to load driver model: ' .. modelName)
        return nil
    end

    -- Create ped in driver seat
    local ped = CreatePedInsideVehicle(vehicle, 4, modelHash, -1, true, false)

    if not DoesEntityExist(ped) then
        SetModelAsNoLongerNeeded(modelHash)
        return nil
    end

    -- Configure ped
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 46, true)
    SetPedCanBeTargetted(ped, false)

    SetModelAsNoLongerNeeded(modelHash)

    if exitAfter then
        -- Make driver exit after a short delay
        CreateThread(function()
            Wait(2000)  -- Wait 2 seconds

            if DoesEntityExist(ped) and DoesEntityExist(vehicle) then
                -- Task to exit vehicle
                TaskLeaveVehicle(ped, vehicle, 0)

                Wait(3000)  -- Wait for exit animation

                if DoesEntityExist(ped) then
                    -- Walk away
                    local pedCoords = GetEntityCoords(ped)
                    local walkTo = GetOffsetFromEntityInWorldCoords(ped, 0.0, 15.0, 0.0)

                    TaskGoStraightToCoord(ped, walkTo.x, walkTo.y, walkTo.z, 1.0, 10000, 0.0, 0.0)

                    Wait(10000)

                    -- Delete ped after walking away
                    if DoesEntityExist(ped) then
                        DeleteEntity(ped)
                    end
                end
            end
        end)
    end

    return ped
end

-- ============================================
-- STREET SPAWN VERIFICATION
-- ============================================

---Find a safe ground position (client-side verification)
---@param coords vector3
---@return vector3
local function FindSafeGroundPosition(coords)
    local found, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 10.0, false)

    if found then
        return vector3(coords.x, coords.y, groundZ + 0.5)
    end

    -- Fallback: try multiple heights
    for offset = -5.0, 10.0, 2.0 do
        found, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + offset, false)
        if found then
            return vector3(coords.x, coords.y, groundZ + 0.5)
        end
    end

    return coords
end

-- ============================================
-- REQUEST DELIVERY
-- ============================================

---Request delivery for a vehicle
---@param plate string
function RequestDelivery(plate)
    if not Config.Delivery or not Config.Delivery.enabled then
        Bridge.Notify('Delivery service is disabled', 'error')
        return
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    -- Build input options
    local inputOptions = {
        { type = 'checkbox', label = 'Rush Delivery', description = 'Faster delivery (costs more)' },
    }

    -- Check if player might have NPC driver access (we don't know tier client-side)
    table.insert(inputOptions, {
        type = 'checkbox',
        label = 'NPC Driver',
        description = 'Have a driver deliver the car (VIP Silver+ only)'
    })

    local input = Bridge.Input('Request Vehicle Delivery', inputOptions)

    if input then
        local options = {
            rush = input[1] == true,
            withDriver = input[2] == true,
        }

        TriggerServerEvent('dps-parking:server:requestDelivery', plate, {
            x = coords.x,
            y = coords.y,
            z = coords.z,
            h = heading
        }, options)
    end
end

-- ============================================
-- EVENTS
-- ============================================

RegisterNetEvent('dps-parking:client:deliveryArrived', function(data)
    local vehicle = NetworkGetEntityFromNetworkId(data.netId)

    -- Wait for vehicle to exist
    local timeout = 50
    while not DoesEntityExist(vehicle) and timeout > 0 do
        Wait(100)
        vehicle = NetworkGetEntityFromNetworkId(data.netId)
        timeout = timeout - 1
    end

    if not DoesEntityExist(vehicle) then
        Bridge.Notify('Failed to locate delivered vehicle', 'error')
        return
    end

    -- Verify ground position
    local vehicleCoords = GetEntityCoords(vehicle)
    local safeCoords = FindSafeGroundPosition(vehicleCoords)

    if #(vehicleCoords - safeCoords) > 1.0 then
        SetEntityCoords(vehicle, safeCoords.x, safeCoords.y, safeCoords.z, false, false, false, false)
    end

    -- Restore full vehicle state
    if data.vehicleData then
        RestoreVehicleState(vehicle, data.vehicleData)
    end

    -- Spawn NPC driver if requested
    if data.withDriver then
        SpawnNPCDriver(vehicle, true)  -- true = exit after delivery
    end

    -- Give keys
    Bridge.GiveKeys(data.plate, vehicle)

    -- Create tracking blip
    local blip = AddBlipForEntity(vehicle)
    SetBlipSprite(blip, 225)  -- Car icon
    SetBlipColour(blip, 2)    -- Green
    SetBlipScale(blip, 0.9)
    SetBlipFlashes(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Delivered: ' .. data.plate)
    EndTextCommandSetBlipName(blip)

    activeDeliveryBlips[data.plate] = blip

    -- Remove blip after 2 minutes
    SetTimeout(120000, function()
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
        activeDeliveryBlips[data.plate] = nil
    end)

    -- Play sound/notification
    PlaySoundFrontend(-1, 'BASE_JUMP_PASSED', 'HUD_AWARDS', false)
end)

-- ============================================
-- ACTIVE DELIVERIES UI
-- ============================================

---Show active deliveries menu
function ShowActiveDeliveries()
    Bridge.TriggerCallback('dps-parking:server:getActiveDeliveries', function(deliveries)
        if not deliveries or #deliveries == 0 then
            Bridge.Notify('No active deliveries', 'info')
            return
        end

        local options = {}

        for _, delivery in ipairs(deliveries) do
            local minutesLeft = math.ceil(delivery.timeLeft / 60)
            local rushLabel = delivery.rush and ' (Rush)' or ''
            local driverLabel = delivery.withDriver and ' + Driver' or ''

            table.insert(options, {
                title = delivery.plate .. rushLabel .. driverLabel,
                description = ('Arriving in %d minute(s)'):format(minutesLeft),
                icon = 'car',
                onSelect = function()
                    -- Option to cancel
                    local confirm = lib.alertDialog({
                        header = 'Cancel Delivery?',
                        content = 'You will receive a 75% refund.',
                        centered = true,
                        cancel = true
                    })

                    if confirm == 'confirm' then
                        TriggerServerEvent('dps-parking:server:cancelDelivery', delivery.id)
                    end
                end
            })
        end

        Bridge.ContextMenu('delivery_active', 'Active Deliveries', options)
    end)
end

-- ============================================
-- CLEANUP
-- ============================================

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Remove all delivery blips
    for plate, blip in pairs(activeDeliveryBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
end)

-- ============================================
-- EXPORTS
-- ============================================

exports('RequestDelivery', RequestDelivery)
exports('ShowActiveDeliveries', ShowActiveDeliveries)

print('^2[DPS-Parking] Delivery module (client) loaded^0')
