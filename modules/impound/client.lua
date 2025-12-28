--[[
    DPS-Parking - Impound System Module (Client)
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Client-side impound interactions:
    - Impound lot NPCs
    - Vehicle retrieval UI
    - Police impound actions
]]

local impoundPeds = {}
local impoundBlips = {}

-- ============================================
-- IMPOUND LOT SETUP
-- ============================================

---Spawn impound lot NPC
---@param lot table
local function SpawnImpoundPed(lot)
    if impoundPeds[lot.id] then return end

    local model = lot.npcModel or 's_m_m_security_01'
    local modelHash = GetHashKey(model)

    RequestModel(modelHash)
    local timeout = 50
    while not HasModelLoaded(modelHash) and timeout > 0 do
        Wait(100)
        timeout = timeout - 1
    end

    if not HasModelLoaded(modelHash) then return end

    local coords = lot.npcCoords or lot.coords
    local ped = CreatePed(4, modelHash, coords.x, coords.y, coords.z - 1.0, coords.w or 0.0, false, true)

    if not DoesEntityExist(ped) then
        SetModelAsNoLongerNeeded(modelHash)
        return
    end

    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)

    if lot.scenario then
        TaskStartScenarioInPlace(ped, lot.scenario, 0, true)
    end

    SetModelAsNoLongerNeeded(modelHash)
    impoundPeds[lot.id] = ped

    AddImpoundTarget(lot, ped)
end

---Add target to impound NPC
---@param lot table
---@param ped number
local function AddImpoundTarget(lot, ped)
    local target = Bridge.Resources.GetTarget()
    if not target then return end

    local options = {
        {
            name = 'impound_retrieve_' .. lot.id,
            icon = 'fas fa-car',
            label = 'Retrieve Vehicle',
            onSelect = function()
                OpenImpoundMenu(lot)
            end,
        },
    }

    if target == 'ox_target' then
        exports.ox_target:addLocalEntity(ped, options)
    elseif target == 'qb-target' then
        exports['qb-target']:AddTargetEntity(ped, {
            options = options,
            distance = 2.5
        })
    end
end

---Create impound blip
---@param lot table
local function CreateImpoundBlip(lot)
    if impoundBlips[lot.id] then return end
    if not lot.blip then return end

    local blip = AddBlipForCoord(lot.coords.x, lot.coords.y, lot.coords.z)
    SetBlipSprite(blip, lot.blip.sprite or 524)
    SetBlipColour(blip, lot.blip.color or 1)
    SetBlipScale(blip, lot.blip.scale or 0.8)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(lot.name or 'Impound Lot')
    EndTextCommandSetBlipName(blip)

    impoundBlips[lot.id] = blip
end

-- ============================================
-- IMPOUND MENU
-- ============================================

---Open impound retrieval menu
---@param lot table
function OpenImpoundMenu(lot)
    Bridge.TriggerCallback('dps-parking:server:getImpoundedVehicles', function(vehicles)
        if not vehicles or #vehicles == 0 then
            Bridge.Notify('You have no impounded vehicles', 'info')
            return
        end

        local options = {}

        for _, v in ipairs(vehicles) do
            local discountLabel = v.discount > 0 and (' (-%d%% insured)'):format(v.discount) or ''

            table.insert(options, {
                title = v.plate,
                description = ('%s - Fee: $%d%s'):format(v.reason, v.fee, discountLabel),
                icon = 'car',
                onSelect = function()
                    ConfirmRetrieve(v, lot)
                end
            })
        end

        Bridge.ContextMenu('impound_list', 'Impounded Vehicles', options)
    end)
end

---Confirm retrieval dialog
---@param vehicle table
---@param lot table
function ConfirmRetrieve(vehicle, lot)
    if Bridge.Resources.HasOxLib() then
        local confirm = lib.alertDialog({
            header = 'Retrieve ' .. vehicle.plate,
            content = ('Pay $%d to retrieve your vehicle?\n\nReason: %s'):format(vehicle.fee, vehicle.reason),
            centered = true,
            cancel = true,
        })

        if confirm == 'confirm' then
            TriggerServerEvent('dps-parking:server:retrieveFromImpound', vehicle.plate)
        end
    else
        -- Fallback without ox_lib
        TriggerServerEvent('dps-parking:server:retrieveFromImpound', vehicle.plate)
    end
end

-- ============================================
-- POLICE IMPOUND ACTIONS
-- ============================================

---Open police impound menu (for officers)
function OpenPoliceImpoundMenu()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle == 0 then
        -- Check for nearby vehicle
        local coords = GetEntityCoords(ped)
        vehicle = GetClosestVehicle(coords.x, coords.y, coords.z, 5.0, 0, 71)
    end

    if vehicle == 0 then
        Bridge.Notify('No vehicle nearby', 'error')
        return
    end

    local plate = GetVehicleNumberPlateText(vehicle)

    local reasons = {
        { value = 'parking', label = 'Illegal Parking - $250' },
        { value = 'abandoned', label = 'Abandoned Vehicle - $500' },
        { value = 'traffic', label = 'Traffic Violation - $750' },
        { value = 'crime', label = 'Criminal Activity - $1,500' },
        { value = 'police', label = 'Police Seizure - $2,500' },
    }

    if Bridge.Resources.HasOxLib() then
        local input = lib.inputDialog('Impound Vehicle: ' .. plate, {
            { type = 'select', label = 'Reason', options = reasons, required = true },
            { type = 'textarea', label = 'Notes (optional)', placeholder = 'Additional details...' },
        })

        if input then
            TriggerServerEvent('dps-parking:server:impoundVehicle', plate, input[1], input[2])

            -- Delete vehicle
            if NetworkHasControlOfEntity(vehicle) then
                DeleteEntity(vehicle)
            else
                NetworkRequestControlOfEntity(vehicle)
                Wait(100)
                DeleteEntity(vehicle)
            end
        end
    else
        -- Simplified without ox_lib
        TriggerServerEvent('dps-parking:server:impoundVehicle', plate, 'parking', nil)
        DeleteEntity(vehicle)
    end
end

-- ============================================
-- EVENTS
-- ============================================

-- Spawn vehicle after retrieval
RegisterNetEvent('dps-parking:client:spawnFromImpound', function(data)
    -- Get spawn point from config
    local spawnPoint = nil

    if Config.Impound and Config.Impound.lots then
        -- Find closest lot
        local playerCoords = GetEntityCoords(PlayerPedId())
        local closestDist = 9999

        for _, lot in ipairs(Config.Impound.lots) do
            local dist = #(playerCoords - vector3(lot.coords.x, lot.coords.y, lot.coords.z))
            if dist < closestDist then
                closestDist = dist
                spawnPoint = lot.spawnPoint or lot.coords
            end
        end
    end

    if not spawnPoint then
        -- Use player position offset
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        local heading = GetEntityHeading(ped)
        local forward = GetOffsetFromEntityInWorldCoords(ped, 0.0, 5.0, 0.0)
        spawnPoint = vector4(forward.x, forward.y, forward.z, heading)
    end

    -- Get vehicle data from server and spawn
    Bridge.TriggerCallback('dps-parking:server:getVehicleData', function(vehicleData)
        if not vehicleData then
            Bridge.Notify('Error spawning vehicle', 'error')
            return
        end

        local model = vehicleData.model or vehicleData.vehicle
        local modelHash = type(model) == 'string' and GetHashKey(model) or model

        RequestModel(modelHash)
        local timeout = 50
        while not HasModelLoaded(modelHash) and timeout > 0 do
            Wait(100)
            timeout = timeout - 1
        end

        local vehicle = CreateVehicle(modelHash, spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnPoint.w or 0.0, true, false)

        if DoesEntityExist(vehicle) then
            SetVehicleNumberPlateText(vehicle, data.plate)

            if vehicleData.mods then
                Bridge.SetVehicleProperties(vehicle, vehicleData.mods)
            end

            Bridge.GiveKeys(data.plate, vehicle)

            local blip = AddBlipForEntity(vehicle)
            SetBlipSprite(blip, 225)
            SetBlipColour(blip, 2)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentString('Retrieved: ' .. data.plate)
            EndTextCommandSetBlipName(blip)

            SetTimeout(60000, function()
                if DoesBlipExist(blip) then RemoveBlip(blip) end
            end)
        end

        SetModelAsNoLongerNeeded(modelHash)
    end, data.plate)
end)

-- ============================================
-- KEYBIND FOR POLICE
-- ============================================

-- Optional: Register keybind for police impound
if Config.Impound and Config.Impound.policeKeybind then
    RegisterKeyMapping('impound_vehicle', 'Impound Vehicle', 'keyboard', Config.Impound.policeKeybind)
    RegisterCommand('impound_vehicle', function()
        local job = Bridge.GetJobName()
        local authorizedJobs = { 'police', 'sheriff', 'highway', 'sasp', 'bcso' }

        for _, j in ipairs(authorizedJobs) do
            if job == j then
                OpenPoliceImpoundMenu()
                return
            end
        end
    end, false)
end

-- ============================================
-- INITIALIZATION
-- ============================================

CreateThread(function()
    Wait(2000)

    if not Config.Impound or not Config.Impound.enabled then
        return
    end

    local lots = Config.Impound.lots or {}

    for _, lot in ipairs(lots) do
        SpawnImpoundPed(lot)
        CreateImpoundBlip(lot)
    end
end)

-- ============================================
-- CLEANUP
-- ============================================

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    for _, ped in pairs(impoundPeds) do
        if DoesEntityExist(ped) then DeleteEntity(ped) end
    end

    for _, blip in pairs(impoundBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
end)

-- ============================================
-- EXPORTS
-- ============================================

exports('OpenPoliceImpoundMenu', OpenPoliceImpoundMenu)
exports('OpenImpoundMenu', OpenImpoundMenu)

print('^2[DPS-Parking] Impound module (client) loaded^0')
