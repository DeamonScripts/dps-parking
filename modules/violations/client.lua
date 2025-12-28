--[[
    DPS-Parking - Parking Violations Module (Client)
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Client-side ticket interactions:
    - View tickets UI
    - Pay tickets
    - Contest tickets
    - Police ticket issuing
]]

-- ============================================
-- TICKET VIEWING
-- ============================================

---Open tickets menu
function OpenTicketsMenu()
    Bridge.TriggerCallback('dps-parking:server:getMyTickets', function(tickets)
        if not tickets or #tickets == 0 then
            Bridge.Notify('You have no parking tickets', 'success')
            return
        end

        local options = {}

        for _, ticket in ipairs(tickets) do
            local statusIcon = 'clock'
            local statusColor = 'yellow'

            if ticket.status == 'paid' then
                statusIcon = 'check'
                statusColor = 'green'
            elseif ticket.status == 'contested' then
                statusIcon = 'gavel'
                statusColor = 'blue'
            elseif ticket.status == 'dismissed' then
                statusIcon = 'times'
                statusColor = 'gray'
            end

            local lateLabel = ticket.isLate and ' (LATE FEE)' or ''

            table.insert(options, {
                title = ticket.plate .. ' - ' .. ticket.type,
                description = ('$%d%s - %s'):format(ticket.fine, lateLabel, ticket.status:upper()),
                icon = statusIcon,
                onSelect = function()
                    if ticket.status == 'unpaid' then
                        OpenTicketActions(ticket)
                    else
                        Bridge.Notify('Ticket is ' .. ticket.status, 'info')
                    end
                end
            })
        end

        Bridge.ContextMenu('my_tickets', 'My Parking Tickets', options)
    end)
end

---Open actions for a specific ticket
---@param ticket table
function OpenTicketActions(ticket)
    local options = {
        {
            title = 'Pay Ticket',
            description = ('Pay $%d now'):format(ticket.fine),
            icon = 'credit-card',
            onSelect = function()
                TriggerServerEvent('dps-parking:server:payTicket', ticket.id)
            end
        },
        {
            title = 'Contest Ticket',
            description = 'Dispute this ticket',
            icon = 'gavel',
            onSelect = function()
                OpenContestDialog(ticket)
            end
        },
    }

    Bridge.ContextMenu('ticket_actions', 'Ticket: ' .. ticket.plate, options)
end

---Open contest dialog
---@param ticket table
function OpenContestDialog(ticket)
    if Bridge.Resources.HasOxLib() then
        local input = lib.inputDialog('Contest Ticket: ' .. ticket.plate, {
            { type = 'textarea', label = 'Reason for Contest', required = true, placeholder = 'Explain why this ticket should be dismissed...' }
        })

        if input and input[1] then
            TriggerServerEvent('dps-parking:server:contestTicket', ticket.id, input[1])
        end
    else
        TriggerServerEvent('dps-parking:server:contestTicket', ticket.id, 'Ticket contested')
    end
end

-- ============================================
-- POLICE TICKETING
-- ============================================

---Open police ticketing menu
function OpenPoliceTicketMenu()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local vehicle = GetClosestVehicle(coords.x, coords.y, coords.z, 10.0, 0, 71)

    if vehicle == 0 then
        Bridge.Notify('No vehicle nearby', 'error')
        return
    end

    local plate = GetVehicleNumberPlateText(vehicle)

    local violations = {
        { value = 'expired_meter', label = 'Expired Meter - $75' },
        { value = 'no_parking', label = 'No Parking Zone - $150' },
        { value = 'fire_lane', label = 'Fire Lane - $250' },
        { value = 'handicap', label = 'Handicap Zone - $500' },
        { value = 'double_parked', label = 'Double Parked - $200' },
        { value = 'blocking', label = 'Blocking Traffic - $300' },
        { value = 'hydrant', label = 'Fire Hydrant - $350' },
    }

    if Bridge.Resources.HasOxLib() then
        local input = lib.inputDialog('Issue Ticket: ' .. plate, {
            { type = 'select', label = 'Violation', options = violations, required = true },
            { type = 'textarea', label = 'Notes (optional)' },
        })

        if input then
            TriggerServerEvent('dps-parking:server:issueTicket', plate, input[1], input[2])
        end
    else
        -- Quick ticket without dialog
        local options = {}
        for _, v in ipairs(violations) do
            table.insert(options, {
                title = v.label,
                onSelect = function()
                    TriggerServerEvent('dps-parking:server:issueTicket', plate, v.value, nil)
                end
            })
        end
        Bridge.ContextMenu('issue_ticket', 'Issue Ticket: ' .. plate, options)
    end
end

-- ============================================
-- EVENTS
-- ============================================

-- Received a ticket notification
RegisterNetEvent('dps-parking:client:receivedTicket', function(ticket)
    -- Play sound
    PlaySoundFrontend(-1, 'CONFIRM_BEEP', 'HUD_MINI_GAME_SOUNDSET', false)

    -- Show notification
    if Bridge.Resources.HasOxLib() then
        lib.notify({
            title = 'Parking Ticket!',
            description = ('%s - $%d'):format(ticket.typeLabel, ticket.fine),
            type = 'error',
            duration = 10000,
        })
    end
end)

-- ============================================
-- COMMANDS
-- ============================================

RegisterCommand('tickets', function()
    OpenTicketsMenu()
end, false)

RegisterCommand('issueticket', function()
    local job = Bridge.GetJobName()
    local authorizedJobs = { 'police', 'sheriff', 'parking_enforcement' }

    for _, j in ipairs(authorizedJobs) do
        if job == j then
            OpenPoliceTicketMenu()
            return
        end
    end

    Bridge.Notify('Not authorized', 'error')
end, false)

-- ============================================
-- EXPORTS
-- ============================================

exports('OpenTicketsMenu', OpenTicketsMenu)
exports('OpenPoliceTicketMenu', OpenPoliceTicketMenu)

print('^2[DPS-Parking] Violations module (client) loaded^0')
