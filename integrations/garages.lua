--[[
    DPS-Parking - Garage Integration Bridge
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Hooks into existing garage scripts for vehicle storage:
    - jg-advancedgarages
    - qs-advancedgarages
    - qb-garages
    - cd_garage
    - esx_garages

    Used by Valet and Impound modules to store/retrieve vehicles
    through the server's existing garage infrastructure.
]]

Garages = {}

-- Detected garage script
Garages._script = nil
Garages._ready = false

-- ============================================
-- DETECTION
-- ============================================

---Detect which garage script is running
---@return string|nil scriptName
function Garages.Detect()
    if Garages._script then
        return Garages._script
    end

    local scripts = {
        'jg-advancedgarages',
        'qs-advancedgarages',
        'qb-garages',
        'cd_garage',
        'esx_garages',
        'okokGarage',
        'renewed-vehiclekeys', -- Some use this for garage
    }

    for _, script in ipairs(scripts) do
        if GetResourceState(script) == 'started' then
            Garages._script = script
            Utils.Debug('Garage integration: detected ' .. script)
            return script
        end
    end

    Utils.Debug('Garage integration: no supported garage script found')
    return nil
end

---Check if garage integration is available
---@return boolean
function Garages.IsAvailable()
    return Garages.Detect() ~= nil
end

-- ============================================
-- VEHICLE STORAGE (Server-side)
-- ============================================

---Store vehicle in garage
---@param citizenid string
---@param plate string
---@param garageId string|nil
---@param vehicleData table|nil
---@return boolean success
function Garages.StoreVehicle(citizenid, plate, garageId, vehicleData)
    local script = Garages.Detect()
    if not script then
        -- Fallback: use our own storage
        return Garages.FallbackStore(citizenid, plate, garageId, vehicleData)
    end

    garageId = garageId or 'valet'

    if script == 'jg-advancedgarages' then
        -- JG Advanced Garages
        local success = exports['jg-advancedgarages']:setVehicleState(plate, 1, garageId)
        return success ~= false

    elseif script == 'qs-advancedgarages' then
        -- QS Advanced Garages
        exports['qs-advancedgarages']:SetVehicleStatus(plate, 1) -- 1 = stored
        return true

    elseif script == 'qb-garages' then
        -- QB-Garages
        local tbl = Bridge.DB.GetVehicleTable()
        local state = Bridge.DB.GetStateColumn()
        MySQL.update.await(
            ('UPDATE %s SET %s = 1, garage = ? WHERE plate = ?'):format(tbl, state),
            {garageId, plate}
        )
        return true

    elseif script == 'cd_garage' then
        -- Codesign Garage
        exports['cd_garage']:SetVehicleState(plate, 'stored')
        return true

    elseif script == 'esx_garages' then
        -- ESX Garages
        MySQL.update.await(
            'UPDATE owned_vehicles SET stored = 1 WHERE plate = ?',
            {plate}
        )
        return true

    elseif script == 'okokGarage' then
        exports['okokGarage']:SetVehicleStatus(plate, true)
        return true
    end

    return Garages.FallbackStore(citizenid, plate, garageId, vehicleData)
end

---Retrieve vehicle from garage (mark as out)
---@param citizenid string
---@param plate string
---@return boolean success
function Garages.RetrieveVehicle(citizenid, plate)
    local script = Garages.Detect()
    if not script then
        return Garages.FallbackRetrieve(citizenid, plate)
    end

    if script == 'jg-advancedgarages' then
        exports['jg-advancedgarages']:setVehicleState(plate, 0, nil)
        return true

    elseif script == 'qs-advancedgarages' then
        exports['qs-advancedgarages']:SetVehicleStatus(plate, 0) -- 0 = out
        return true

    elseif script == 'qb-garages' then
        local tbl = Bridge.DB.GetVehicleTable()
        local state = Bridge.DB.GetStateColumn()
        MySQL.update.await(
            ('UPDATE %s SET %s = 0 WHERE plate = ?'):format(tbl, state),
            {plate}
        )
        return true

    elseif script == 'cd_garage' then
        exports['cd_garage']:SetVehicleState(plate, 'out')
        return true

    elseif script == 'esx_garages' then
        MySQL.update.await(
            'UPDATE owned_vehicles SET stored = 0 WHERE plate = ?',
            {plate}
        )
        return true

    elseif script == 'okokGarage' then
        exports['okokGarage']:SetVehicleStatus(plate, false)
        return true
    end

    return Garages.FallbackRetrieve(citizenid, plate)
end

---Get vehicle state from garage
---@param plate string
---@return string state ('stored', 'out', 'impound', 'unknown')
function Garages.GetVehicleState(plate)
    local script = Garages.Detect()
    if not script then
        return Garages.FallbackGetState(plate)
    end

    if script == 'jg-advancedgarages' then
        local state = exports['jg-advancedgarages']:getVehicleState(plate)
        if state == 1 then return 'stored'
        elseif state == 0 then return 'out'
        elseif state == 2 then return 'impound'
        end
        return 'unknown'

    elseif script == 'qs-advancedgarages' then
        local status = exports['qs-advancedgarages']:GetVehicleStatus(plate)
        if status == 1 then return 'stored'
        elseif status == 0 then return 'out'
        elseif status == 2 then return 'impound'
        end
        return 'unknown'

    elseif script == 'qb-garages' or script == 'esx_garages' then
        local tbl = Bridge.DB.GetVehicleTable()
        local stateCol = Bridge.DB.GetStateColumn()
        local result = MySQL.query.await(
            ('SELECT %s FROM %s WHERE plate = ?'):format(stateCol, tbl),
            {plate}
        )
        if result and result[1] then
            local state = result[1][stateCol]
            if state == 1 then return 'stored'
            elseif state == 0 then return 'out'
            elseif state == 2 then return 'impound'
            end
        end
        return 'unknown'
    end

    return 'unknown'
end

---Get vehicles in a specific garage
---@param garageId string
---@return table vehicles
function Garages.GetGarageVehicles(garageId)
    local script = Garages.Detect()
    if not script then return {} end

    if script == 'jg-advancedgarages' then
        return exports['jg-advancedgarages']:getGarageVehicles(garageId) or {}

    elseif script == 'qb-garages' then
        local tbl = Bridge.DB.GetVehicleTable()
        local state = Bridge.DB.GetStateColumn()
        return MySQL.query.await(
            ('SELECT * FROM %s WHERE garage = ? AND %s = 1'):format(tbl, state),
            {garageId}
        ) or {}
    end

    return {}
end

-- ============================================
-- IMPOUND INTEGRATION
-- ============================================

---Send vehicle to impound
---@param plate string
---@param reason string
---@param fee number
---@return boolean success
function Garages.ImpoundVehicle(plate, reason, fee)
    local script = Garages.Detect()

    if script == 'jg-advancedgarages' then
        exports['jg-advancedgarages']:setVehicleState(plate, 2, 'impound')
        return true

    elseif script == 'qs-advancedgarages' then
        exports['qs-advancedgarages']:SetVehicleStatus(plate, 2)
        return true

    elseif script == 'qb-garages' then
        local tbl = Bridge.DB.GetVehicleTable()
        local stateCol = Bridge.DB.GetStateColumn()
        MySQL.update.await(
            ('UPDATE %s SET %s = 2, garage = "impound" WHERE plate = ?'):format(tbl, stateCol),
            {plate}
        )
        return true

    elseif script == 'cd_garage' then
        exports['cd_garage']:SetVehicleState(plate, 'impound')
        return true
    end

    -- Fallback
    local tbl = Bridge.DB.GetVehicleTable()
    local stateCol = Bridge.DB.GetStateColumn()
    MySQL.update.await(
        ('UPDATE %s SET %s = 2 WHERE plate = ?'):format(tbl, stateCol),
        {plate}
    )
    return true
end

---Retrieve vehicle from impound
---@param plate string
---@param paidFee number
---@return boolean success
function Garages.RetrieveFromImpound(plate, paidFee)
    local script = Garages.Detect()

    if script == 'jg-advancedgarages' then
        exports['jg-advancedgarages']:setVehicleState(plate, 0, nil)
        return true

    elseif script == 'qs-advancedgarages' then
        exports['qs-advancedgarages']:SetVehicleStatus(plate, 0)
        return true

    elseif script == 'qb-garages' or script == 'esx_garages' then
        local tbl = Bridge.DB.GetVehicleTable()
        local stateCol = Bridge.DB.GetStateColumn()
        MySQL.update.await(
            ('UPDATE %s SET %s = 0, garage = NULL WHERE plate = ?'):format(tbl, stateCol),
            {plate}
        )
        return true

    elseif script == 'cd_garage' then
        exports['cd_garage']:SetVehicleState(plate, 'out')
        return true
    end

    return false
end

-- ============================================
-- FALLBACK STORAGE (Our own tables)
-- ============================================

---Fallback store when no garage script detected
---@param citizenid string
---@param plate string
---@param garageId string
---@param vehicleData table
---@return boolean
function Garages.FallbackStore(citizenid, plate, garageId, vehicleData)
    local tbl = Bridge.DB.GetVehicleTable()
    local stateCol = Bridge.DB.GetStateColumn()

    MySQL.update.await(
        ('UPDATE %s SET %s = 1 WHERE plate = ?'):format(tbl, stateCol),
        {plate}
    )

    return true
end

---Fallback retrieve
---@param citizenid string
---@param plate string
---@return boolean
function Garages.FallbackRetrieve(citizenid, plate)
    local tbl = Bridge.DB.GetVehicleTable()
    local stateCol = Bridge.DB.GetStateColumn()

    MySQL.update.await(
        ('UPDATE %s SET %s = 0 WHERE plate = ?'):format(tbl, stateCol),
        {plate}
    )

    return true
end

---Fallback get state
---@param plate string
---@return string
function Garages.FallbackGetState(plate)
    local tbl = Bridge.DB.GetVehicleTable()
    local stateCol = Bridge.DB.GetStateColumn()

    local result = MySQL.query.await(
        ('SELECT %s FROM %s WHERE plate = ?'):format(stateCol, tbl),
        {plate}
    )

    if result and result[1] then
        local state = result[1][stateCol]
        if state == 1 then return 'stored'
        elseif state == 0 then return 'out'
        elseif state == 2 then return 'impound'
        end
    end

    return 'unknown'
end

-- ============================================
-- INITIALIZATION
-- ============================================

CreateThread(function()
    Wait(3000)
    local script = Garages.Detect()
    if script then
        print('^2[DPS-Parking] Garage integration: hooked into ' .. script .. '^0')
    else
        print('^3[DPS-Parking] Garage integration: using fallback storage^0')
    end
    Garages._ready = true
end)

print('^2[DPS-Parking] Garage integration bridge loaded^0')

return Garages
