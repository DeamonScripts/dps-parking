--[[
    DPS-Parking - Reserved Spots Module (Server)
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Reserved parking spot system:
    - VIP-only spots
    - Job-restricted spots
    - Business employee spots
    - Rental spots
]]

Reserved = {}

-- Active reservations
Reserved._spots = {}          -- spotId -> spot data
Reserved._playerRentals = {}  -- citizenid -> array of spotIds

-- ============================================
-- CONFIGURATION
-- ============================================

Reserved.Config = {
    -- Rental pricing (per hour)
    rentalPricePerHour = 50,
    maxRentalHours = 24,
    -- VIP discounts on rentals
    vipDiscounts = {
        bronze = 0.10,
        silver = 0.20,
        gold = 0.35,
        platinum = 0.50,
    },
}

-- ============================================
-- SPOT MANAGEMENT
-- ============================================

---Initialize reserved spots from config
function Reserved.Initialize()
    if not Config.Reserved or not Config.Reserved.spots then
        return
    end

    for _, spot in ipairs(Config.Reserved.spots) do
        Reserved._spots[spot.id] = {
            id = spot.id,
            name = spot.name or ('Spot ' .. spot.id),
            coords = spot.coords,
            type = spot.type or 'vip',  -- vip, job, business, rental
            -- For job spots
            requiredJob = spot.requiredJob,
            requiredGrade = spot.requiredGrade,
            -- For business spots
            businessId = spot.businessId,
            -- Current occupant
            occupant = nil,
            occupantPlate = nil,
            occupiedAt = nil,
            -- For rentals
            rentedBy = nil,
            rentalExpires = nil,
        }
    end

    print(('[DPS-Parking] Reserved: Initialized %d spots'):format(#Config.Reserved.spots))
end

---Check if player can use a spot
---@param source number
---@param spotId string
---@return boolean canUse
---@return string reason
function Reserved.CanUseSpot(source, spotId)
    local spot = Reserved._spots[spotId]
    if not spot then
        return false, 'Spot not found'
    end

    local citizenid = Bridge.GetCitizenId(source)

    -- Check if spot is rented by someone else
    if spot.rentedBy and spot.rentedBy ~= citizenid then
        if spot.rentalExpires and spot.rentalExpires > os.time() then
            return false, 'Spot is rented by another player'
        else
            -- Rental expired, clear it
            spot.rentedBy = nil
            spot.rentalExpires = nil
        end
    end

    -- Check by spot type
    if spot.type == 'vip' then
        if not State.IsVip(citizenid) then
            return false, 'VIP membership required'
        end
        return true, 'VIP access granted'

    elseif spot.type == 'job' then
        local playerJob = Bridge.GetPlayerJob(source)

        if playerJob ~= spot.requiredJob then
            return false, ('Requires %s job'):format(spot.requiredJob)
        end

        -- Check grade if specified
        if spot.requiredGrade then
            local player = Bridge.GetPlayer(source)
            local grade = 0

            if Bridge.IsESX() then
                grade = player.job.grade
            else
                grade = player.PlayerData.job.grade.level
            end

            if grade < spot.requiredGrade then
                return false, 'Insufficient job grade'
            end
        end

        -- Check on-duty if required
        if spot.requireOnDuty and not Bridge.IsOnDuty(source) then
            return false, 'Must be on duty'
        end

        return true, 'Job access granted'

    elseif spot.type == 'business' then
        -- Check if player owns or works at the business
        local owner = State.GetBusinessOwner(spot.businessId)

        if owner then
            if owner.citizenid == citizenid then
                return true, 'Business owner access'
            end

            -- Check employees
            if owner.employees then
                for _, emp in pairs(owner.employees) do
                    if emp.citizenid == citizenid then
                        return true, 'Employee access'
                    end
                end
            end
        end

        return false, 'Business access required'

    elseif spot.type == 'rental' then
        -- Check if player rented this spot
        if spot.rentedBy == citizenid then
            if spot.rentalExpires and spot.rentalExpires > os.time() then
                return true, 'Your rental'
            else
                return false, 'Rental expired'
            end
        end

        -- Spot is rentable
        if not spot.rentedBy then
            return false, 'Spot available for rental'
        end

        return false, 'Spot rented by another'
    end

    return false, 'Unknown spot type'
end

---Occupy a reserved spot
---@param source number
---@param spotId string
---@param plate string
---@return boolean success
---@return string message
function Reserved.OccupySpot(source, spotId, plate)
    local canUse, reason = Reserved.CanUseSpot(source, spotId)

    if not canUse then
        return false, reason
    end

    local spot = Reserved._spots[spotId]
    local citizenid = Bridge.GetCitizenId(source)

    -- Check if spot is already occupied
    if spot.occupant and spot.occupant ~= citizenid then
        return false, 'Spot is occupied'
    end

    spot.occupant = citizenid
    spot.occupantPlate = plate
    spot.occupiedAt = os.time()

    EventBus.Publish('reserved:spotOccupied', {
        spotId = spotId,
        citizenid = citizenid,
        plate = plate,
    })

    return true, 'Reserved spot occupied'
end

---Vacate a reserved spot
---@param spotId string
---@param plate string
function Reserved.VacateSpot(spotId, plate)
    local spot = Reserved._spots[spotId]
    if not spot then return end

    if spot.occupantPlate == plate then
        spot.occupant = nil
        spot.occupantPlate = nil
        spot.occupiedAt = nil

        EventBus.Publish('reserved:spotVacated', {
            spotId = spotId,
            plate = plate,
        })
    end
end

-- ============================================
-- RENTALS
-- ============================================

---Rent a parking spot
---@param source number
---@param spotId string
---@param hours number
---@return boolean success
---@return string message
function Reserved.RentSpot(source, spotId, hours)
    local spot = Reserved._spots[spotId]

    if not spot then
        return false, 'Spot not found'
    end

    if spot.type ~= 'rental' then
        return false, 'This spot is not available for rental'
    end

    -- Check if already rented
    if spot.rentedBy then
        if spot.rentalExpires and spot.rentalExpires > os.time() then
            return false, 'Spot is currently rented'
        end
    end

    local citizenid = Bridge.GetCitizenId(source)
    hours = math.min(hours, Reserved.Config.maxRentalHours)

    -- Calculate price
    local price = Reserved.Config.rentalPricePerHour * hours

    -- Apply VIP discount
    local vipData = State.GetVipPlayer(citizenid)
    if vipData and vipData.tier then
        local discount = Reserved.Config.vipDiscounts[vipData.tier] or 0
        price = math.floor(price * (1 - discount))
    end

    -- Check funds
    if Bridge.GetMoney(source, 'bank') < price then
        if Bridge.GetMoney(source, 'cash') < price then
            return false, L('insufficient_funds', Utils.FormatMoney(price))
        end
    end

    -- Charge
    if Bridge.GetMoney(source, 'bank') >= price then
        Bridge.RemoveMoney(source, 'bank', price, 'Parking spot rental')
    else
        Bridge.RemoveMoney(source, 'cash', price, 'Parking spot rental')
    end

    -- Set rental
    spot.rentedBy = citizenid
    spot.rentalExpires = os.time() + (hours * 3600)

    -- Track for player
    if not Reserved._playerRentals[citizenid] then
        Reserved._playerRentals[citizenid] = {}
    end
    table.insert(Reserved._playerRentals[citizenid], spotId)

    EventBus.Publish('reserved:spotRented', {
        spotId = spotId,
        citizenid = citizenid,
        hours = hours,
        price = price,
    })

    return true, ('Spot rented for %d hour(s) - $%d'):format(hours, price)
end

---Get player's rentals
---@param citizenid string
---@return table rentals
function Reserved.GetPlayerRentals(citizenid)
    local rentals = {}

    for spotId, spot in pairs(Reserved._spots) do
        if spot.rentedBy == citizenid then
            local timeLeft = spot.rentalExpires and (spot.rentalExpires - os.time()) or 0

            table.insert(rentals, {
                spotId = spotId,
                name = spot.name,
                coords = spot.coords,
                expiresAt = spot.rentalExpires,
                timeLeftMinutes = math.max(0, math.floor(timeLeft / 60)),
            })
        end
    end

    return rentals
end

---Get available rental spots
---@return table spots
function Reserved.GetAvailableRentals()
    local available = {}

    for spotId, spot in pairs(Reserved._spots) do
        if spot.type == 'rental' then
            local isAvailable = not spot.rentedBy or (spot.rentalExpires and spot.rentalExpires < os.time())

            if isAvailable then
                table.insert(available, {
                    spotId = spotId,
                    name = spot.name,
                    coords = spot.coords,
                    pricePerHour = Reserved.Config.rentalPricePerHour,
                })
            end
        end
    end

    return available
end

-- ============================================
-- VIOLATION CHECK
-- ============================================

---Check if a vehicle is parked in an unauthorized reserved spot
---@param plate string
---@param spotId string
---@param citizenid string
---@return boolean isViolation
function Reserved.CheckViolation(plate, spotId, citizenid)
    local spot = Reserved._spots[spotId]
    if not spot then return false end

    -- Get player source from citizenid
    local player = Bridge.GetPlayerByCitizenId(citizenid)
    if not player then return true end  -- Can't verify, assume violation

    local playerSource = Bridge.IsESX() and player.source or player.PlayerData.source
    if not playerSource then return true end

    local canUse, _ = Reserved.CanUseSpot(playerSource, spotId)
    return not canUse
end

-- ============================================
-- EVENTS
-- ============================================

RegisterNetEvent('dps-parking:server:rentSpot', function(spotId, hours)
    local source = source
    local success, message = Reserved.RentSpot(source, spotId, hours)
    Bridge.Notify(source, message, success and 'success' or 'error')
end)

RegisterNetEvent('dps-parking:server:occupyReserved', function(spotId, plate)
    local source = source
    local success, message = Reserved.OccupySpot(source, spotId, plate)
    if not success then
        Bridge.Notify(source, message, 'error')
    end
end)

-- Callbacks
Bridge.CreateCallback('dps-parking:server:getMyRentals', function(source, cb)
    local citizenid = Bridge.GetCitizenId(source)
    cb(Reserved.GetPlayerRentals(citizenid))
end)

Bridge.CreateCallback('dps-parking:server:getAvailableRentals', function(source, cb)
    cb(Reserved.GetAvailableRentals())
end)

Bridge.CreateCallback('dps-parking:server:canUseSpot', function(source, cb, spotId)
    local canUse, reason = Reserved.CanUseSpot(source, spotId)
    cb({ canUse = canUse, reason = reason })
end)

-- ============================================
-- INITIALIZATION
-- ============================================

CreateThread(function()
    Wait(2000)
    Reserved.Initialize()
end)

print('^2[DPS-Parking] Reserved spots module (server) loaded^0')

return Reserved
