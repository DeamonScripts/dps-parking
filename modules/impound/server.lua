--[[
    DPS-Parking - Impound System Module (Server)
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Police impound integration with:
    - Tiered fees based on offense
    - Insurance integration for discounts
    - Time-based fee increases
    - Retrieval locations
]]

Impound = {}

-- Track impounded vehicles (in-memory, synced with garage script)
Impound._vehicles = {}

-- ============================================
-- CONFIGURATION
-- ============================================

Impound.Config = {
    baseFee = 500,
    -- Fee tiers based on offense
    tiers = {
        parking = { fee = 250, label = 'Illegal Parking' },
        abandoned = { fee = 500, label = 'Abandoned Vehicle' },
        traffic = { fee = 750, label = 'Traffic Violation' },
        crime = { fee = 1500, label = 'Criminal Activity' },
        police = { fee = 2500, label = 'Police Seizure' },
    },
    -- Daily fee increase
    dailyFeeIncrease = 100,
    maxDailyFees = 10,  -- Cap at 10 days of fees
    -- Jobs that can impound
    authorizedJobs = { 'police', 'sheriff', 'highway', 'sasp', 'bcso' },
    -- Require on-duty for impound
    requireOnDuty = true,
}

-- ============================================
-- IMPOUND OPERATIONS
-- ============================================

---Impound a vehicle (police action)
---@param source number Officer source
---@param plate string
---@param reason string Tier key
---@param notes string|nil
---@return boolean success
---@return string message
function Impound.ImpoundVehicle(source, plate, reason, notes)
    -- Use Permissions bridge for authorization
    local canImpound, permReason = Permissions.CanImpound(source, reason)

    if not canImpound then
        return false, permReason
    end

    -- Get tier
    local tier = Impound.Config.tiers[reason] or Impound.Config.tiers['parking']

    -- Store impound data
    local officerName = Bridge.GetPlayerName(source)
    local impoundData = {
        plate = plate,
        reason = reason,
        reasonLabel = tier.label,
        baseFee = tier.fee,
        impoundedAt = os.time(),
        impoundedBy = officerName,
        notes = notes,
        retrieved = false,
    }

    Impound._vehicles[plate] = impoundData

    -- Update garage system
    if Garages and Garages.IsAvailable() then
        Garages.ImpoundVehicle(plate, tier.label, tier.fee)
    else
        -- Fallback DB update
        Bridge.DB.SetVehicleImpounded(plate, 1000, 1000, 100)
    end

    -- Audit log
    if DB and DB.AuditLog then
        DB.AuditLog('impound', Bridge.GetCitizenId(source), plate, {
            reason = reason,
            fee = tier.fee,
            officer = officerName,
            notes = notes,
        })
    end

    -- Publish event
    EventBus.Publish('impound:vehicleImpounded', {
        plate = plate,
        reason = reason,
        fee = tier.fee,
        officer = source,
    })

    return true, ('Vehicle %s impounded for: %s'):format(plate, tier.label)
end

---Calculate current impound fee
---@param plate string
---@return number fee
---@return number discount
---@return string reason
function Impound.CalculateFee(plate)
    local impoundData = Impound._vehicles[plate]

    if not impoundData then
        -- Check database
        local state = Garages and Garages.GetVehicleState(plate) or 'unknown'
        if state ~= 'impound' then
            return 0, 0, 'Vehicle not impounded'
        end
        -- Use base fee if no data
        return Impound.Config.baseFee, 0, 'Standard impound'
    end

    local baseFee = impoundData.baseFee
    local daysImpounded = math.floor((os.time() - impoundData.impoundedAt) / 86400)
    daysImpounded = math.min(daysImpounded, Impound.Config.maxDailyFees)

    local dailyFees = daysImpounded * Impound.Config.dailyFeeIncrease
    local totalFee = baseFee + dailyFees

    -- Check insurance discount
    local discountedFee = totalFee
    local discountPercent = 0

    if Insurance and Insurance.IsAvailable() then
        discountedFee, discountPercent = Insurance.CalculateImpoundDiscount(plate, totalFee)
    end

    return discountedFee, discountPercent, impoundData.reasonLabel
end

---Retrieve vehicle from impound
---@param source number
---@param plate string
---@return boolean success
---@return string message
function Impound.RetrieveVehicle(source, plate)
    local citizenid = Bridge.GetCitizenId(source)
    if not citizenid then
        return false, L('error')
    end

    -- Verify ownership
    if not Bridge.DB.PlayerOwnsVehicle(citizenid, plate) then
        return false, L('not_owner')
    end

    -- Check if impounded
    local state = Garages and Garages.GetVehicleState(plate) or 'unknown'
    if state ~= 'impound' and not Impound._vehicles[plate] then
        return false, 'Vehicle is not impounded'
    end

    -- Calculate fee
    local fee, discount, reason = Impound.CalculateFee(plate)

    -- Check funds
    if Bridge.GetMoney(source, 'bank') < fee then
        if Bridge.GetMoney(source, 'cash') < fee then
            return false, L('insufficient_funds', Utils.FormatMoney(fee))
        end
    end

    -- Charge player
    if Bridge.GetMoney(source, 'bank') >= fee then
        Bridge.RemoveMoney(source, 'bank', fee, 'Impound fee')
    else
        Bridge.RemoveMoney(source, 'cash', fee, 'Impound fee')
    end

    -- Process insurance claim if available
    if Insurance and Insurance.IsAvailable() and discount > 0 then
        Insurance.ProcessClaim(plate, 'impound', fee)
    end

    -- Update garage system
    if Garages and Garages.IsAvailable() then
        Garages.RetrieveFromImpound(plate, fee)
    else
        Bridge.DB.SetVehicleOut(plate)
    end

    -- Cleanup
    Impound._vehicles[plate] = nil

    -- Audit log
    if DB and DB.AuditLog then
        DB.AuditLog('impound_retrieve', citizenid, plate, {
            fee = fee,
            discount = discount,
        })
    end

    -- Publish event
    EventBus.Publish('impound:vehicleRetrieved', {
        plate = plate,
        citizenid = citizenid,
        fee = fee,
        discount = discount,
    })

    return true, ('Vehicle retrieved - Paid: %s%s'):format(
        Utils.FormatMoney(fee),
        discount > 0 and (' (%d%% insurance discount)'):format(discount) or ''
    )
end

---Get impound details for a vehicle
---@param plate string
---@return table|nil details
function Impound.GetDetails(plate)
    local impoundData = Impound._vehicles[plate]
    if not impoundData then
        return nil
    end

    local fee, discount, reason = Impound.CalculateFee(plate)
    local daysImpounded = math.floor((os.time() - impoundData.impoundedAt) / 86400)

    return {
        plate = plate,
        reason = impoundData.reasonLabel,
        impoundedAt = impoundData.impoundedAt,
        daysImpounded = daysImpounded,
        baseFee = impoundData.baseFee,
        currentFee = fee,
        insuranceDiscount = discount,
        notes = impoundData.notes,
        impoundedBy = impoundData.impoundedBy,
    }
end

---Get all impounded vehicles for a player
---@param citizenid string
---@return table vehicles
function Impound.GetPlayerVehicles(citizenid)
    local vehicles = {}

    -- Check our cache
    for plate, data in pairs(Impound._vehicles) do
        if Bridge.DB.PlayerOwnsVehicle(citizenid, plate) then
            local fee, discount, _ = Impound.CalculateFee(plate)
            table.insert(vehicles, {
                plate = plate,
                reason = data.reasonLabel,
                fee = fee,
                discount = discount,
                impoundedAt = data.impoundedAt,
            })
        end
    end

    return vehicles
end

-- ============================================
-- ADMIN FUNCTIONS
-- ============================================

---Release vehicle without fee (admin)
---@param source number
---@param plate string
---@return boolean success
---@return string message
function Impound.AdminRelease(source, plate)
    if not Bridge.IsAdmin(source) then
        return false, 'Not authorized'
    end

    if Garages and Garages.IsAvailable() then
        Garages.RetrieveFromImpound(plate, 0)
    else
        Bridge.DB.SetVehicleOut(plate)
    end

    Impound._vehicles[plate] = nil

    if DB and DB.AuditLog then
        DB.AuditLog('impound_admin_release', Bridge.GetCitizenId(source), plate, {
            admin = Bridge.GetPlayerName(source),
        })
    end

    return true, 'Vehicle released by admin'
end

-- ============================================
-- EVENTS
-- ============================================

RegisterNetEvent('dps-parking:server:impoundVehicle', function(plate, reason, notes)
    local source = source
    local success, message = Impound.ImpoundVehicle(source, plate, reason, notes)
    Bridge.Notify(source, message, success and 'success' or 'error')
end)

RegisterNetEvent('dps-parking:server:retrieveFromImpound', function(plate)
    local source = source
    local success, message = Impound.RetrieveVehicle(source, plate)
    Bridge.Notify(source, message, success and 'success' or 'error')

    if success then
        -- Notify client to spawn vehicle
        TriggerClientEvent('dps-parking:client:spawnFromImpound', source, { plate = plate })
    end
end)

RegisterNetEvent('dps-parking:server:adminReleaseVehicle', function(plate)
    local source = source
    local success, message = Impound.AdminRelease(source, plate)
    Bridge.Notify(source, message, success and 'success' or 'error')
end)

-- Callbacks
Bridge.CreateCallback('dps-parking:server:getImpoundedVehicles', function(source, cb)
    local citizenid = Bridge.GetCitizenId(source)
    cb(Impound.GetPlayerVehicles(citizenid))
end)

Bridge.CreateCallback('dps-parking:server:getImpoundFee', function(source, cb, plate)
    local fee, discount, reason = Impound.CalculateFee(plate)
    cb({ fee = fee, discount = discount, reason = reason })
end)

print('^2[DPS-Parking] Impound module (server) loaded^0')

return Impound
