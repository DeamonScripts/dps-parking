--[[
    DPS-Parking - Reserved Spots Module (Client)
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Client-side reserved spot interactions:
    - Spot markers/props
    - Rental UI
    - Access validation
]]

local reservedMarkers = {}
local reservedBlips = {}

-- ============================================
-- SPOT VISUALIZATION
-- ============================================

---Draw reserved spot markers
local function DrawReservedMarkers()
    if not Config.Reserved or not Config.Reserved.spots then return end

    local playerCoords = GetEntityCoords(PlayerPedId())

    for _, spot in ipairs(Config.Reserved.spots) do
        local dist = #(playerCoords - vector3(spot.coords.x, spot.coords.y, spot.coords.z))

        if dist < 50.0 then
            -- Draw marker
            local color = { r = 255, g = 255, b = 0, a = 100 }  -- Yellow default

            if spot.type == 'vip' then
                color = { r = 255, g = 215, b = 0, a = 100 }  -- Gold
            elseif spot.type == 'job' then
                color = { r = 0, g = 100, b = 255, a = 100 }  -- Blue
            elseif spot.type == 'business' then
                color = { r = 0, g = 255, b = 100, a = 100 }  -- Green
            elseif spot.type == 'rental' then
                color = { r = 150, g = 50, b = 255, a = 100 }  -- Purple
            end

            DrawMarker(
                1,  -- Cylinder
                spot.coords.x, spot.coords.y, spot.coords.z - 0.5,
                0.0, 0.0, 0.0,
                0.0, 0.0, 0.0,
                2.5, 5.0, 0.5,
                color.r, color.g, color.b, color.a,
                false, false, 2, false, nil, nil, false
            )

            -- Draw 3D text when close
            if dist < 10.0 then
                local label = spot.name or 'Reserved'
                Utils.Draw3DText(spot.coords.x, spot.coords.y, spot.coords.z + 0.5, label)
            end
        end
    end
end

-- ============================================
-- RENTAL UI
-- ============================================

---Open rental spots menu
function OpenRentalMenu()
    Bridge.TriggerCallback('dps-parking:server:getAvailableRentals', function(spots)
        if not spots or #spots == 0 then
            Bridge.Notify('No rental spots available', 'info')
            return
        end

        local options = {}

        for _, spot in ipairs(spots) do
            table.insert(options, {
                title = spot.name,
                description = ('$%d/hour'):format(spot.pricePerHour),
                icon = 'parking',
                onSelect = function()
                    OpenRentDurationMenu(spot)
                end
            })
        end

        Bridge.ContextMenu('rental_spots', 'Available Rental Spots', options)
    end)
end

---Open duration selection for rental
---@param spot table
function OpenRentDurationMenu(spot)
    local durations = {
        { hours = 1, label = '1 Hour' },
        { hours = 2, label = '2 Hours' },
        { hours = 4, label = '4 Hours' },
        { hours = 8, label = '8 Hours' },
        { hours = 12, label = '12 Hours' },
        { hours = 24, label = '24 Hours' },
    }

    local options = {}

    for _, d in ipairs(durations) do
        local price = spot.pricePerHour * d.hours

        table.insert(options, {
            title = d.label,
            description = ('$%d total'):format(price),
            onSelect = function()
                TriggerServerEvent('dps-parking:server:rentSpot', spot.spotId, d.hours)

                -- Set GPS to spot
                SetNewWaypoint(spot.coords.x, spot.coords.y)
            end
        })
    end

    Bridge.ContextMenu('rent_duration', 'Rent: ' .. spot.name, options)
end

---Show my rentals
function ShowMyRentals()
    Bridge.TriggerCallback('dps-parking:server:getMyRentals', function(rentals)
        if not rentals or #rentals == 0 then
            Bridge.Notify('You have no active rentals', 'info')
            return
        end

        local options = {}

        for _, rental in ipairs(rentals) do
            local timeLabel = rental.timeLeftMinutes > 60 and
                ('%d hr %d min remaining'):format(math.floor(rental.timeLeftMinutes / 60), rental.timeLeftMinutes % 60) or
                ('%d min remaining'):format(rental.timeLeftMinutes)

            table.insert(options, {
                title = rental.name,
                description = timeLabel,
                icon = 'clock',
                onSelect = function()
                    SetNewWaypoint(rental.coords.x, rental.coords.y)
                    Bridge.Notify('GPS set to your rental spot', 'info')
                end
            })
        end

        Bridge.ContextMenu('my_rentals', 'My Rental Spots', options)
    end)
end

-- ============================================
-- SPOT VALIDATION
-- ============================================

---Check if player can park in current spot
---@param coords vector3
---@return boolean canPark
---@return string|nil spotId
local function CheckReservedSpot(coords)
    if not Config.Reserved or not Config.Reserved.spots then
        return true, nil
    end

    for _, spot in ipairs(Config.Reserved.spots) do
        local dist = #(coords - vector3(spot.coords.x, spot.coords.y, spot.coords.z))

        if dist < 3.0 then
            -- In a reserved spot - check access
            local canUse = lib.callback.await('dps-parking:server:canUseSpot', false, spot.id)

            if canUse and canUse.canUse then
                return true, spot.id
            else
                return false, spot.id
            end
        end
    end

    return true, nil
end

-- Hook into parking to validate reserved spots
EventBus.RegisterPreHook('parking:park', function(data)
    if not Config.Reserved or not Config.Reserved.enabled then
        return true
    end

    local canPark, spotId = CheckReservedSpot(data.location)

    if not canPark then
        Bridge.Notify('This is a reserved parking spot', 'error')
        return false
    end

    -- If valid reserved spot, notify server
    if spotId then
        TriggerServerEvent('dps-parking:server:occupyReserved', spotId, data.plate)
    end

    return true, data
end, EventBus.Priority.HIGH)

-- ============================================
-- MARKER THREAD
-- ============================================

CreateThread(function()
    Wait(3000)

    if not Config.Reserved or not Config.Reserved.enabled then
        return
    end

    if not Config.Reserved.showMarkers then
        return
    end

    while true do
        DrawReservedMarkers()
        Wait(0)
    end
end)

-- ============================================
-- COMMANDS
-- ============================================

RegisterCommand('rentspot', function()
    OpenRentalMenu()
end, false)

RegisterCommand('myrentals', function()
    ShowMyRentals()
end, false)

-- ============================================
-- EXPORTS
-- ============================================

exports('OpenRentalMenu', OpenRentalMenu)
exports('ShowMyRentals', ShowMyRentals)

print('^2[DPS-Parking] Reserved spots module (client) loaded^0')
