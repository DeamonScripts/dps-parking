--[[
    DPS-Parking - Valet Service Module (Client)
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Client-side valet interactions:
    - NPC valet peds at locations
    - Target/interaction system
    - Animations and vehicle handoff
    - Retrieval spawning
]]

local valetPeds = {}
local valetBlips = {}
local activeSession = nil

-- Valet NPC models
local valetModels = {
    's_m_m_valet_01',
    'a_m_y_business_01',
    's_m_y_valet_01',
}

-- ============================================
-- VALET PED SPAWNING
-- ============================================

---Spawn valet NPC at location
---@param location table
local function SpawnValetPed(location)
    if valetPeds[location.id] then return end

    local model = location.npcModel or valetModels[math.random(#valetModels)]
    local modelHash = GetHashKey(model)

    RequestModel(modelHash)
    local timeout = 50
    while not HasModelLoaded(modelHash) and timeout > 0 do
        Wait(100)
        timeout = timeout - 1
    end

    if not HasModelLoaded(modelHash) then
        Utils.Debug('Failed to load valet model: ' .. model)
        return
    end

    local coords = location.coords
    local ped = CreatePed(4, modelHash, coords.x, coords.y, coords.z - 1.0, coords.w or 0.0, false, true)

    if not DoesEntityExist(ped) then
        SetModelAsNoLongerNeeded(modelHash)
        return
    end

    -- Configure ped
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 46, true)
    SetPedCanBeTargetted(ped, false)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)

    -- Scenario
    if location.scenario then
        TaskStartScenarioInPlace(ped, location.scenario, 0, true)
    else
        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_CLIPBOARD', 0, true)
    end

    SetModelAsNoLongerNeeded(modelHash)

    valetPeds[location.id] = ped

    -- Add target interaction
    AddValetTarget(location, ped)

    Utils.Debug('Spawned valet ped at: ' .. location.name)
end

---Add target interaction to valet ped
---@param location table
---@param ped number
local function AddValetTarget(location, ped)
    local target = Bridge.Resources.GetTarget()
    if not target then return end

    local options = {
        {
            name = 'valet_park_' .. location.id,
            icon = 'fas fa-car',
            label = 'Valet Parking',
            onSelect = function()
                OpenValetMenu(location, 'park')
            end,
            canInteract = function()
                local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
                return vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == PlayerPedId()
            end
        },
        {
            name = 'valet_retrieve_' .. location.id,
            icon = 'fas fa-key',
            label = 'Retrieve Vehicle',
            onSelect = function()
                OpenValetMenu(location, 'retrieve')
            end,
            canInteract = function()
                return not IsPedInAnyVehicle(PlayerPedId(), false)
            end
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

---Create valet blip
---@param location table
local function CreateValetBlip(location)
    if valetBlips[location.id] then return end
    if not location.blip then return end

    local blip = AddBlipForCoord(location.coords.x, location.coords.y, location.coords.z)
    SetBlipSprite(blip, location.blip.sprite or 811)
    SetBlipColour(blip, location.blip.color or 5)
    SetBlipScale(blip, location.blip.scale or 0.7)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(location.name or 'Valet Parking')
    EndTextCommandSetBlipName(blip)

    valetBlips[location.id] = blip
end

-- ============================================
-- VALET MENU
-- ============================================

---Open valet interaction menu
---@param location table
---@param mode string 'park' or 'retrieve'
function OpenValetMenu(location, mode)
    if mode == 'park' then
        OpenParkMenu(location)
    elseif mode == 'retrieve' then
        OpenRetrieveMenu(location)
    end
end

---Open parking menu with tip options
---@param location table
function OpenParkMenu(location)
    local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
    if vehicle == 0 then
        Bridge.Notify('You must be in a vehicle', 'error')
        return
    end

    local plate = GetVehicleNumberPlateText(vehicle)
    local basePrice = Config.Valet and Config.Valet.basePrice or 100

    local options = {
        {
            title = 'Standard Service',
            description = ('$%d - Normal wait time'):format(basePrice),
            icon = 'clock',
            onSelect = function()
                RequestValetPark(location.id, 'none')
            end
        },
        {
            title = 'Small Tip (+$50)',
            description = ('$%d - 25%% faster'):format(basePrice + 50),
            icon = 'dollar-sign',
            onSelect = function()
                RequestValetPark(location.id, 'small')
            end
        },
        {
            title = 'Medium Tip (+$100)',
            description = ('$%d - 50%% faster'):format(basePrice + 100),
            icon = 'dollar-sign',
            onSelect = function()
                RequestValetPark(location.id, 'medium')
            end
        },
        {
            title = 'Large Tip (+$200)',
            description = ('$%d - 75%% faster (Priority)'):format(basePrice + 200),
            icon = 'star',
            onSelect = function()
                RequestValetPark(location.id, 'large')
            end
        },
    }

    Bridge.ContextMenu('valet_park', 'Valet Parking - ' .. plate, options)
end

---Open retrieval menu
---@param location table
function OpenRetrieveMenu(location)
    Bridge.TriggerCallback('dps-parking:server:getValetVehicles', function(vehicles)
        if not vehicles or #vehicles == 0 then
            Bridge.Notify('You have no vehicles parked with valet', 'info')
            return
        end

        local options = {}
        local retrievePrice = Config.Valet and Config.Valet.retrievalPrice or 50

        for _, v in ipairs(vehicles) do
            -- Only show vehicles at this location
            if v.locationId == location.id then
                table.insert(options, {
                    title = v.plate,
                    description = 'Parked ' .. FormatTimeAgo(v.parkedAt),
                    icon = 'car',
                    onSelect = function()
                        OpenTipMenuForRetrieval(v.plate, retrievePrice)
                    end
                })
            end
        end

        if #options == 0 then
            Bridge.Notify('No vehicles parked at this location', 'info')
            return
        end

        Bridge.ContextMenu('valet_retrieve', 'Retrieve Vehicle', options)
    end)
end

---Open tip menu for retrieval
---@param plate string
---@param basePrice number
function OpenTipMenuForRetrieval(plate, basePrice)
    local options = {
        {
            title = 'Standard Retrieval',
            description = ('$%d - Normal wait'):format(basePrice),
            onSelect = function()
                TriggerServerEvent('dps-parking:server:valetRetrieve', plate, 'none')
            end
        },
        {
            title = 'Small Tip (+$25)',
            description = ('$%d - Faster'):format(basePrice + 25),
            onSelect = function()
                TriggerServerEvent('dps-parking:server:valetRetrieve', plate, 'small')
            end
        },
        {
            title = 'Medium Tip (+$50)',
            description = ('$%d - Much faster'):format(basePrice + 50),
            onSelect = function()
                TriggerServerEvent('dps-parking:server:valetRetrieve', plate, 'medium')
            end
        },
        {
            title = 'Large Tip (+$100)',
            description = ('$%d - Priority'):format(basePrice + 100),
            onSelect = function()
                TriggerServerEvent('dps-parking:server:valetRetrieve', plate, 'large')
            end
        },
    }

    Bridge.ContextMenu('valet_retrieve_tip', 'Tip Valet - ' .. plate, options)
end

---Format time ago string
---@param timestamp number
---@return string
function FormatTimeAgo(timestamp)
    local diff = os.time() - timestamp
    if diff < 60 then
        return 'just now'
    elseif diff < 3600 then
        return math.floor(diff / 60) .. ' min ago'
    else
        return math.floor(diff / 3600) .. ' hr ago'
    end
end

-- ============================================
-- VALET ACTIONS
-- ============================================

---Request valet to park vehicle
---@param locationId string
---@param tipLevel string
function RequestValetPark(locationId, tipLevel)
    local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
    if vehicle == 0 then return end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    TriggerServerEvent('dps-parking:server:valetPark', locationId, netId, tipLevel)
end

-- ============================================
-- EVENTS
-- ============================================

-- Valet taking vehicle
RegisterNetEvent('dps-parking:client:valetTakeVehicle', function(data)
    activeSession = data

    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle == 0 then return end

    -- Get vehicle data before handoff
    local vehicleData = nil
    if VehicleData then
        vehicleData = VehicleData.Serialize(vehicle)
    else
        vehicleData = {
            mods = Bridge.GetVehicleProperties(vehicle),
            fuel = Bridge.GetFuel(vehicle),
        }
    end

    -- Send vehicle data to server
    TriggerServerEvent('dps-parking:server:valetStoreData', data.plate, vehicleData)

    -- Exit vehicle
    TaskLeaveVehicle(ped, vehicle, 0)

    -- Progress bar
    Bridge.Progress({
        duration = data.waitTime * 1000,
        label = 'Valet is parking your vehicle...',
        canCancel = false,
        disable = { move = false, car = true, combat = true },
    })
end)

-- Valet finished parking
RegisterNetEvent('dps-parking:client:valetParkComplete', function(data)
    -- Delete the vehicle entity (it's now "parked" by valet)
    local vehicles = GetGamePool('CVehicle')
    for _, vehicle in ipairs(vehicles) do
        if GetVehicleNumberPlateText(vehicle) == data.plate then
            if NetworkHasControlOfEntity(vehicle) then
                DeleteEntity(vehicle)
            else
                NetworkRequestControlOfEntity(vehicle)
                Wait(100)
                if NetworkHasControlOfEntity(vehicle) then
                    DeleteEntity(vehicle)
                end
            end
            break
        end
    end

    activeSession = nil
    PlaySoundFrontend(-1, 'PICKUP_WEAPON_SMOKEGRENADE', 'HUD_FRONTEND_CUSTOM_SOUNDSET', false)
end)

-- Valet retrieving vehicle
RegisterNetEvent('dps-parking:client:valetRetrieving', function(data)
    activeSession = data

    Bridge.Progress({
        duration = data.waitTime * 1000,
        label = 'Valet is retrieving your vehicle...',
        canCancel = false,
        disable = { move = false, car = true, combat = true },
    })
end)

-- Valet delivering vehicle
RegisterNetEvent('dps-parking:client:valetDeliverVehicle', function(data)
    local spawnPoint = data.spawnPoint
    local vehicleData = data.vehicleData

    if not vehicleData or not vehicleData.mods then
        Bridge.Notify('Error retrieving vehicle data', 'error')
        return
    end

    -- Get model
    local model = vehicleData.mods.model or vehicleData.model
    if not model then
        Bridge.Notify('Error: vehicle model unknown', 'error')
        return
    end

    local modelHash = type(model) == 'string' and GetHashKey(model) or model

    -- Load model
    RequestModel(modelHash)
    local timeout = 50
    while not HasModelLoaded(modelHash) and timeout > 0 do
        Wait(100)
        timeout = timeout - 1
    end

    if not HasModelLoaded(modelHash) then
        Bridge.Notify('Failed to load vehicle model', 'error')
        return
    end

    -- Find ground
    local found, groundZ = GetGroundZFor_3dCoord(spawnPoint.x, spawnPoint.y, spawnPoint.z + 5.0, false)
    local z = found and groundZ + 0.5 or spawnPoint.z

    -- Spawn vehicle
    local vehicle = CreateVehicle(modelHash, spawnPoint.x, spawnPoint.y, z, spawnPoint.w or 0.0, true, false)

    if not DoesEntityExist(vehicle) then
        Bridge.Notify('Failed to spawn vehicle', 'error')
        SetModelAsNoLongerNeeded(modelHash)
        return
    end

    -- Set plate
    SetVehicleNumberPlateText(vehicle, data.plate)

    -- Restore full state
    if VehicleData and vehicleData.damage then
        VehicleData.Deserialize(vehicle, vehicleData)
    elseif vehicleData.mods then
        Bridge.SetVehicleProperties(vehicle, vehicleData.mods)
    end

    if vehicleData.fuel then
        Bridge.SetFuel(vehicle, vehicleData.fuel)
    end

    -- Give keys
    Bridge.GiveKeys(data.plate, vehicle)

    SetModelAsNoLongerNeeded(modelHash)

    -- Create temp blip
    local blip = AddBlipForEntity(vehicle)
    SetBlipSprite(blip, 225)
    SetBlipColour(blip, 2)
    SetBlipScale(blip, 0.8)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Your Vehicle')
    EndTextCommandSetBlipName(blip)

    SetTimeout(60000, function()
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end)

    activeSession = nil
    PlaySoundFrontend(-1, 'BASE_JUMP_PASSED', 'HUD_AWARDS', false)
end)

-- ============================================
-- INITIALIZATION
-- ============================================

CreateThread(function()
    Wait(2000)

    if not Config.Valet or not Config.Valet.enabled then
        return
    end

    local locations = Config.Valet.locations or {}

    for _, location in ipairs(locations) do
        SpawnValetPed(location)
        CreateValetBlip(location)
    end

    Utils.Debug('Valet module initialized with ' .. #locations .. ' locations')
end)

-- ============================================
-- CLEANUP
-- ============================================

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    for id, ped in pairs(valetPeds) do
        if DoesEntityExist(ped) then
            DeleteEntity(ped)
        end
    end

    for id, blip in pairs(valetBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
end)

print('^2[DPS-Parking] Valet module (client) loaded^0')
