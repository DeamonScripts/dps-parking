--[[
    DPS-Parking - Dispatch Integration
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Integration with dispatch systems for parking violations:
    - qs-dispatch (primary)
    - ps-dispatch
    - cd_dispatch

    Sends alerts for:
    - Expired meters
    - No-parking violations
    - Abandoned vehicles
    - Illegally parked vehicles
]]

Dispatch = {}

-- Detected dispatch script
Dispatch._script = nil

-- ============================================
-- DETECTION
-- ============================================

---Detect which dispatch script is running
---@return string|nil
function Dispatch.Detect()
    if Dispatch._script then
        return Dispatch._script
    end

    local scripts = {
        'qs-dispatch',
        'ps-dispatch',
        'cd_dispatch',
        'origen_dispatch',
        'rcore_dispatch',
    }

    for _, script in ipairs(scripts) do
        if GetResourceState(script) == 'started' then
            Dispatch._script = script
            return script
        end
    end

    return nil
end

---Check if dispatch is available
---@return boolean
function Dispatch.IsAvailable()
    return Dispatch.Detect() ~= nil
end

-- ============================================
-- DISPATCH ALERTS
-- ============================================

---Send parking violation alert
---@param data table { type, plate, location, street, description }
function Dispatch.SendParkingAlert(data)
    local script = Dispatch.Detect()
    if not script then return end

    local coords = data.location or vector3(0, 0, 0)
    local street = data.street or 'Unknown Location'

    if script == 'qs-dispatch' then
        TriggerEvent('qs-dispatch:server:CreateDispatchCall', {
            job = 'police',
            callLocation = coords,
            callCode = { code = '10-50', snippet = 'Parking Violation' },
            message = data.description or 'Parking violation reported',
            flashes = false,
            image = nil,
            blip = {
                sprite = 326,
                scale = 1.0,
                colour = 5,
                flashes = false,
                text = 'Parking Violation',
                time = 5,
            },
            -- Additional qs-dispatch fields
            plate = data.plate,
            street = street,
            alertType = 'parking',
        })

    elseif script == 'ps-dispatch' then
        exports['ps-dispatch']:CustomAlert({
            coords = coords,
            message = data.description or 'Parking Violation',
            dispatchCode = '10-50 Parking',
            description = ('Plate: %s\nLocation: %s'):format(data.plate or 'Unknown', street),
            radius = 0,
            sprite = 326,
            color = 5,
            scale = 1.0,
            length = 3,
            jobs = { 'police', 'sheriff' },
        })

    elseif script == 'cd_dispatch' then
        TriggerEvent('cd_dispatch:AddNotification', {
            job_table = { 'police', 'sheriff' },
            coords = coords,
            title = '10-50 Parking Violation',
            message = data.description or 'Parking violation reported',
            flash = 0,
            unique_id = 'parking_' .. tostring(os.time()),
            blip = {
                sprite = 326,
                scale = 1.0,
                colour = 5,
                flashes = false,
                text = 'Parking Violation - ' .. (data.plate or ''),
                time = (5 * 60 * 1000),
                radius = 0,
            },
        })
    end

    Utils.Debug(('Dispatch: Sent parking alert - %s at %s'):format(data.type or 'violation', street))
end

---Send expired meter alert
---@param plate string
---@param location vector3
---@param street string
function Dispatch.ExpiredMeter(plate, location, street)
    Dispatch.SendParkingAlert({
        type = 'expired_meter',
        plate = plate,
        location = location,
        street = street,
        description = ('Expired parking meter - Plate: %s'):format(plate),
    })
end

---Send no-parking zone alert
---@param plate string
---@param location vector3
---@param street string
---@param zoneType string
function Dispatch.NoParkingViolation(plate, location, street, zoneType)
    local zoneLabels = {
        no_parking = 'No Parking Zone',
        fire_lane = 'Fire Lane',
        handicap = 'Handicap Zone',
        hydrant = 'Fire Hydrant',
        bus_stop = 'Bus Stop',
        loading = 'Loading Zone',
    }

    Dispatch.SendParkingAlert({
        type = zoneType,
        plate = plate,
        location = location,
        street = street,
        description = ('Illegal parking in %s - Plate: %s'):format(
            zoneLabels[zoneType] or 'restricted zone',
            plate
        ),
    })
end

---Send abandoned vehicle alert
---@param plate string
---@param location vector3
---@param street string
---@param hoursParked number
function Dispatch.AbandonedVehicle(plate, location, street, hoursParked)
    Dispatch.SendParkingAlert({
        type = 'abandoned',
        plate = plate,
        location = location,
        street = street,
        description = ('Abandoned vehicle (parked %d+ hours) - Plate: %s'):format(
            hoursParked,
            plate
        ),
    })
end

---Send vehicle blocking traffic alert
---@param plate string
---@param location vector3
---@param street string
function Dispatch.BlockingTraffic(plate, location, street)
    Dispatch.SendParkingAlert({
        type = 'blocking',
        plate = plate,
        location = location,
        street = street,
        description = ('Vehicle blocking traffic - Plate: %s'):format(plate),
    })
end

-- ============================================
-- EVENTBUS HOOKS
-- ============================================

-- Auto-dispatch on meter expiry (if enabled)
EventBus.Subscribe('meters:expired', function(data)
    if not Config.Dispatch or not Config.Dispatch.alertOnMeterExpiry then
        return
    end

    Dispatch.ExpiredMeter(data.plate, data.location, data.street or 'Unknown')
end, EventBus.Priority.LOW)

-- Auto-dispatch on zone violation
EventBus.Subscribe('zones:violation', function(data)
    if not Config.Dispatch or not Config.Dispatch.alertOnZoneViolation then
        return
    end

    Dispatch.NoParkingViolation(data.plate, data.location, data.street or 'Unknown', data.zoneType)
end, EventBus.Priority.LOW)

-- ============================================
-- INITIALIZATION
-- ============================================

CreateThread(function()
    Wait(3000)
    local script = Dispatch.Detect()
    if script then
        print('^2[DPS-Parking] Dispatch integration: hooked into ' .. script .. '^0')
    else
        print('^3[DPS-Parking] Dispatch integration: no dispatch system detected^0')
    end
end)

print('^2[DPS-Parking] Dispatch integration loaded^0')

return Dispatch
