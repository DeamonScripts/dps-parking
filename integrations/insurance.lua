--[[
    DPS-Parking - Insurance Integration Bridge
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Hooks into existing insurance scripts:
    - m-insurance (primary)
    - qs-insurance
    - qb-vehicleinsurance
    - wasabi_insurance
    - esx_insurance

    Used by Impound module for fee calculations and coverage checks.
]]

Insurance = {}

-- Detected insurance script
Insurance._script = nil
Insurance._ready = false

-- ============================================
-- DETECTION
-- ============================================

---Detect which insurance script is running
---@return string|nil scriptName
function Insurance.Detect()
    if Insurance._script then
        return Insurance._script
    end

    local scripts = {
        'm-insurance',           -- User's script
        'qs-insurance',
        'qb-vehicleinsurance',
        'wasabi_insurance',
        'esx_insurance',
        'renewed-insurance',
        'jg-insurance',
    }

    for _, script in ipairs(scripts) do
        if GetResourceState(script) == 'started' then
            Insurance._script = script
            Utils.Debug('Insurance integration: detected ' .. script)
            return script
        end
    end

    Utils.Debug('Insurance integration: no insurance script found')
    return nil
end

---Check if insurance integration is available
---@return boolean
function Insurance.IsAvailable()
    return Insurance.Detect() ~= nil
end

-- ============================================
-- INSURANCE CHECKS (Server-side)
-- ============================================

---Check if vehicle is insured
---@param plate string
---@return boolean insured
function Insurance.IsVehicleInsured(plate)
    local script = Insurance.Detect()
    if not script then
        return false
    end

    if script == 'm-insurance' then
        -- M-Insurance
        local insured = exports['m-insurance']:IsVehicleInsured(plate)
        return insured == true

    elseif script == 'qs-insurance' then
        local insured = exports['qs-insurance']:IsVehicleInsured(plate)
        return insured == true

    elseif script == 'qb-vehicleinsurance' then
        local insured = exports['qb-vehicleinsurance']:IsVehicleInsured(plate)
        return insured == true

    elseif script == 'wasabi_insurance' then
        local insured = exports['wasabi_insurance']:IsInsured(plate)
        return insured == true

    elseif script == 'renewed-insurance' then
        local insured = exports['renewed-insurance']:IsVehicleInsured(plate)
        return insured == true

    elseif script == 'jg-insurance' then
        local insured = exports['jg-insurance']:IsVehicleInsured(plate)
        return insured == true
    end

    return false
end

---Get insurance tier/level for vehicle
---@param plate string
---@return string|nil tier
function Insurance.GetInsuranceTier(plate)
    local script = Insurance.Detect()
    if not script then
        return nil
    end

    if script == 'm-insurance' then
        -- Try to get tier if export exists
        local success, tier = pcall(function()
            return exports['m-insurance']:GetInsuranceTier(plate)
        end)
        return success and tier or 'basic'

    elseif script == 'qs-insurance' then
        local success, tier = pcall(function()
            return exports['qs-insurance']:GetInsuranceTier(plate)
        end)
        return success and tier or 'basic'

    elseif script == 'qb-vehicleinsurance' then
        local success, tier = pcall(function()
            return exports['qb-vehicleinsurance']:GetTier(plate)
        end)
        return success and tier or 'basic'
    end

    return 'basic'
end

---Calculate impound fee discount based on insurance
---@param plate string
---@param baseFee number
---@return number discountedFee
---@return number discountPercent
function Insurance.CalculateImpoundDiscount(plate, baseFee)
    if not Insurance.IsVehicleInsured(plate) then
        return baseFee, 0
    end

    local tier = Insurance.GetInsuranceTier(plate)

    -- Discount tiers
    local discounts = {
        basic = 0.10,      -- 10% off
        standard = 0.25,   -- 25% off
        premium = 0.50,    -- 50% off
        platinum = 0.75,   -- 75% off
        full = 1.0,        -- 100% covered
    }

    local discount = discounts[tier] or discounts['basic']
    local discountAmount = baseFee * discount
    local finalFee = math.max(0, baseFee - discountAmount)

    return math.floor(finalFee), math.floor(discount * 100)
end

---Process insurance claim for vehicle
---@param plate string
---@param claimType string ('impound', 'damage', 'theft')
---@param amount number
---@return boolean success
---@return string message
function Insurance.ProcessClaim(plate, claimType, amount)
    local script = Insurance.Detect()
    if not script then
        return false, 'No insurance system available'
    end

    if not Insurance.IsVehicleInsured(plate) then
        return false, 'Vehicle is not insured'
    end

    if script == 'm-insurance' then
        local success, result = pcall(function()
            return exports['m-insurance']:ProcessClaim(plate, claimType, amount)
        end)
        if success and result then
            return true, 'Claim processed successfully'
        end

    elseif script == 'qs-insurance' then
        local success, result = pcall(function()
            return exports['qs-insurance']:ClaimInsurance(plate, amount)
        end)
        if success then
            return true, 'Claim processed'
        end

    elseif script == 'qb-vehicleinsurance' then
        local success = pcall(function()
            exports['qb-vehicleinsurance']:UseClaim(plate)
        end)
        return success, success and 'Claim used' or 'Claim failed'
    end

    return false, 'Could not process claim'
end

---Get remaining claims for vehicle
---@param plate string
---@return number|nil claims
function Insurance.GetRemainingClaims(plate)
    local script = Insurance.Detect()
    if not script then
        return nil
    end

    if script == 'm-insurance' then
        local success, claims = pcall(function()
            return exports['m-insurance']:GetRemainingClaims(plate)
        end)
        return success and claims or nil

    elseif script == 'qs-insurance' then
        local success, claims = pcall(function()
            return exports['qs-insurance']:GetClaims(plate)
        end)
        return success and claims or nil
    end

    return nil
end

-- ============================================
-- DAMAGE COVERAGE
-- ============================================

---Check if damage is covered by insurance
---@param plate string
---@param damageType string ('body', 'engine', 'windows')
---@return boolean covered
function Insurance.IsDamageCovered(plate, damageType)
    if not Insurance.IsVehicleInsured(plate) then
        return false
    end

    local tier = Insurance.GetInsuranceTier(plate)

    -- Coverage by tier
    local coverage = {
        basic = { body = false, engine = false, windows = false },
        standard = { body = true, engine = false, windows = false },
        premium = { body = true, engine = true, windows = true },
        platinum = { body = true, engine = true, windows = true },
        full = { body = true, engine = true, windows = true },
    }

    local tierCoverage = coverage[tier] or coverage['basic']
    return tierCoverage[damageType] == true
end

---Calculate repair cost with insurance
---@param plate string
---@param baseCost number
---@return number finalCost
---@return boolean usedInsurance
function Insurance.CalculateRepairCost(plate, baseCost)
    if not Insurance.IsVehicleInsured(plate) then
        return baseCost, false
    end

    local tier = Insurance.GetInsuranceTier(plate)

    local discounts = {
        basic = 0.15,
        standard = 0.30,
        premium = 0.50,
        platinum = 0.75,
        full = 1.0,
    }

    local discount = discounts[tier] or 0
    local finalCost = math.max(0, baseCost - (baseCost * discount))

    return math.floor(finalCost), true
end

-- ============================================
-- INITIALIZATION
-- ============================================

CreateThread(function()
    Wait(3000)
    local script = Insurance.Detect()
    if script then
        print('^2[DPS-Parking] Insurance integration: hooked into ' .. script .. '^0')
    else
        print('^3[DPS-Parking] Insurance integration: no insurance script detected^0')
    end
    Insurance._ready = true
end)

print('^2[DPS-Parking] Insurance integration bridge loaded^0')

return Insurance
