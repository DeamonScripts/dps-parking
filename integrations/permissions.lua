--[[
    DPS-Parking - Permissions Bridge
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Unified permission system for parking enforcement:
    - Police rank-based permissions
    - Grade requirements for each action
    - On-duty requirements
    - Configurable per-server
]]

Permissions = {}

-- ============================================
-- CONFIGURATION
-- ============================================

Permissions.Config = {
    -- Jobs that have parking enforcement powers
    -- Each job has grade requirements for different actions
    -- Wasabi Police grade structure (adjust to match your server)
    -- Grade 0: Cadet/Recruit
    -- Grade 1: Officer
    -- Grade 2: Senior Officer
    -- Grade 3: Sergeant
    -- Grade 4: Lieutenant
    -- Grade 5: Captain
    -- Grade 6: Commander/Deputy Chief
    -- Grade 7: Chief

    enforcementJobs = {
        -- Primary: Wasabi Police
        ['police'] = {
            issueTicket = 1,        -- Officer+ can ticket
            checkMeters = 1,        -- Officer+ can check meters
            bootVehicle = 2,        -- Senior Officer+ can boot (future)
            impoundVehicle = 3,     -- Sergeant+ can impound
            impoundCriminal = 2,    -- Senior Officer+ can impound for crimes
            releaseImpound = 4,     -- Lieutenant+ can release without fee
            viewTicketHistory = 1,  -- Officer+ can view
            dismissTicket = 5,      -- Captain+ can dismiss
        },
        ['lspd'] = {  -- Los Santos Police Department
            issueTicket = 1,
            checkMeters = 1,
            bootVehicle = 2,
            impoundVehicle = 3,
            impoundCriminal = 2,
            releaseImpound = 4,
            viewTicketHistory = 1,
            dismissTicket = 5,
        },
        ['sheriff'] = {
            issueTicket = 1,
            checkMeters = 1,
            bootVehicle = 2,
            impoundVehicle = 3,
            impoundCriminal = 2,
            releaseImpound = 4,
            viewTicketHistory = 1,
            dismissTicket = 5,
        },
        ['bcso'] = {  -- Blaine County Sheriff
            issueTicket = 1,
            checkMeters = 1,
            bootVehicle = 2,
            impoundVehicle = 3,
            impoundCriminal = 2,
            releaseImpound = 4,
            viewTicketHistory = 1,
            dismissTicket = 5,
        },
        ['sasp'] = {  -- San Andreas State Police
            issueTicket = 1,
            checkMeters = 1,
            bootVehicle = 2,
            impoundVehicle = 2,  -- State troopers have more impound power
            impoundCriminal = 1,
            releaseImpound = 3,
            viewTicketHistory = 1,
            dismissTicket = 4,
        },
        ['sahp'] = {  -- San Andreas Highway Patrol
            issueTicket = 0,        -- All highway patrol can ticket
            checkMeters = 0,
            bootVehicle = 1,
            impoundVehicle = 1,     -- Highway has more impound authority
            impoundCriminal = 0,
            releaseImpound = 2,
            viewTicketHistory = 0,
            dismissTicket = 3,
        },
        ['highway'] = {
            issueTicket = 0,
            checkMeters = 0,
            bootVehicle = 1,
            impoundVehicle = 1,
            impoundCriminal = 0,
            releaseImpound = 2,
            viewTicketHistory = 0,
            dismissTicket = 3,
        },
        ['ranger'] = {  -- Park Rangers
            issueTicket = 1,
            checkMeters = 1,
            bootVehicle = 2,
            impoundVehicle = 3,
            impoundCriminal = 2,
            releaseImpound = 4,
            viewTicketHistory = 1,
            dismissTicket = 5,
        },
    },

    -- Require on-duty for enforcement actions
    requireOnDuty = true,

    -- Actions and their display names
    actionLabels = {
        issueTicket = 'Issue Parking Ticket',
        checkMeters = 'Check Parking Meters',
        bootVehicle = 'Boot Vehicle',
        impoundVehicle = 'Impound Vehicle (Parking)',
        impoundCriminal = 'Impound Vehicle (Criminal)',
        releaseImpound = 'Release from Impound',
        viewTicketHistory = 'View Ticket History',
        dismissTicket = 'Dismiss Ticket',
    },

    -- Impound reason to permission mapping
    impoundReasons = {
        parking = 'impoundVehicle',
        abandoned = 'impoundVehicle',
        traffic = 'impoundVehicle',
        crime = 'impoundCriminal',
        police = 'impoundCriminal',
    },
}

-- ============================================
-- PERMISSION CHECKS (Server-side)
-- ============================================

---Check if player has a specific parking permission
---@param source number
---@param action string Permission action key
---@return boolean hasPermission
---@return string reason
function Permissions.HasPermission(source, action)
    local player = Bridge.GetPlayer(source)
    if not player then
        return false, 'Player not found'
    end

    -- Get job info
    local jobName, jobGrade
    if Bridge.IsESX() then
        jobName = player.job.name
        jobGrade = player.job.grade
    else
        jobName = player.PlayerData.job.name
        jobGrade = player.PlayerData.job.grade.level
    end

    -- Check if job has enforcement powers
    local jobConfig = Permissions.Config.enforcementJobs[jobName]
    if not jobConfig then
        return false, 'Not an enforcement job'
    end

    -- Check if action exists for this job
    local requiredGrade = jobConfig[action]
    if requiredGrade == nil then
        return false, 'Action not permitted for this job'
    end

    -- Check grade requirement
    if jobGrade < requiredGrade then
        local gradeNeeded = Permissions.GetGradeName(jobName, requiredGrade)
        return false, ('Requires %s or higher'):format(gradeNeeded)
    end

    -- Check on-duty if required
    if Permissions.Config.requireOnDuty then
        if not Bridge.IsOnDuty(source) then
            return false, 'Must be on duty'
        end
    end

    return true, 'Authorized'
end

---Get grade name for display
---@param jobName string
---@param grade number
---@return string
function Permissions.GetGradeName(jobName, grade)
    -- Try to get from framework
    if Bridge.IsQB() then
        local jobs = exports['qb-core']:GetCoreObject().Shared.Jobs
        if jobs and jobs[jobName] and jobs[jobName].grades and jobs[jobName].grades[tostring(grade)] then
            return jobs[jobName].grades[tostring(grade)].name
        end
    end

    -- Fallback names
    local defaultNames = {
        [0] = 'Recruit',
        [1] = 'Officer',
        [2] = 'Senior Officer',
        [3] = 'Sergeant',
        [4] = 'Lieutenant',
        [5] = 'Captain',
        [6] = 'Commander',
        [7] = 'Chief',
    }

    return defaultNames[grade] or ('Grade ' .. grade)
end

---Check permission for impound by reason
---@param source number
---@param reason string Impound reason key
---@return boolean hasPermission
---@return string message
function Permissions.CanImpound(source, reason)
    local action = Permissions.Config.impoundReasons[reason] or 'impoundVehicle'
    return Permissions.HasPermission(source, action)
end

---Get all permissions for a player
---@param source number
---@return table permissions
function Permissions.GetPlayerPermissions(source)
    local perms = {}

    for action, label in pairs(Permissions.Config.actionLabels) do
        local has, reason = Permissions.HasPermission(source, action)
        perms[action] = {
            allowed = has,
            reason = reason,
            label = label,
        }
    end

    return perms
end

---Check if player is any type of enforcement
---@param source number
---@return boolean isEnforcement
---@return string|nil jobName
function Permissions.IsEnforcement(source)
    local player = Bridge.GetPlayer(source)
    if not player then return false, nil end

    local jobName
    if Bridge.IsESX() then
        jobName = player.job.name
    else
        jobName = player.PlayerData.job.name
    end

    if Permissions.Config.enforcementJobs[jobName] then
        return true, jobName
    end

    return false, nil
end

-- ============================================
-- ENFORCEMENT INFO
-- ============================================

---Get enforcement info for UI display
---@param source number
---@return table info
function Permissions.GetEnforcementInfo(source)
    local isEnforcement, jobName = Permissions.IsEnforcement(source)

    if not isEnforcement then
        return {
            isEnforcement = false,
            jobName = nil,
            permissions = {},
        }
    end

    local player = Bridge.GetPlayer(source)
    local gradeName = 'Unknown'

    if Bridge.IsESX() then
        gradeName = player.job.grade_name or player.job.grade_label or 'Officer'
    else
        gradeName = player.PlayerData.job.grade.name or 'Officer'
    end

    return {
        isEnforcement = true,
        jobName = jobName,
        gradeName = gradeName,
        onDuty = Bridge.IsOnDuty(source),
        permissions = Permissions.GetPlayerPermissions(source),
    }
end

-- ============================================
-- CALLBACKS
-- ============================================

Bridge.CreateCallback('dps-parking:server:hasPermission', function(source, cb, action)
    local has, reason = Permissions.HasPermission(source, action)
    cb({ allowed = has, reason = reason })
end)

Bridge.CreateCallback('dps-parking:server:getEnforcementInfo', function(source, cb)
    cb(Permissions.GetEnforcementInfo(source))
end)

Bridge.CreateCallback('dps-parking:server:canImpound', function(source, cb, reason)
    local can, message = Permissions.CanImpound(source, reason)
    cb({ allowed = can, reason = message })
end)

-- ============================================
-- ADMIN OVERRIDE
-- ============================================

---Check if player can bypass permissions (admin)
---@param source number
---@return boolean
function Permissions.IsAdmin(source)
    return Bridge.IsAdmin(source)
end

---Wrapped permission check with admin bypass
---@param source number
---@param action string
---@return boolean
---@return string
function Permissions.Check(source, action)
    -- Admin bypass
    if Permissions.IsAdmin(source) then
        return true, 'Admin override'
    end

    return Permissions.HasPermission(source, action)
end

print('^2[DPS-Parking] Permissions bridge loaded^0')

return Permissions
