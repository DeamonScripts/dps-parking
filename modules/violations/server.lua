--[[
    DPS-Parking - Parking Violations Module (Server)
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Parking ticket system:
    - Meter expiry tickets
    - No-parking zone fines
    - Police ticketing
    - Payment/contest system
]]

Violations = {}

-- Active tickets
Violations._tickets = {}

-- ============================================
-- CONFIGURATION
-- ============================================

Violations.Config = {
    -- Ticket types and fines
    types = {
        expired_meter = { fine = 75, label = 'Expired Meter', points = 0 },
        no_parking = { fine = 150, label = 'No Parking Zone', points = 0 },
        fire_lane = { fine = 250, label = 'Fire Lane Violation', points = 0 },
        handicap = { fine = 500, label = 'Handicap Zone Violation', points = 1 },
        double_parked = { fine = 200, label = 'Double Parked', points = 0 },
        blocking = { fine = 300, label = 'Blocking Traffic', points = 1 },
        hydrant = { fine = 350, label = 'Fire Hydrant Violation', points = 0 },
    },
    -- Time to pay before fee increases
    gracePeriodHours = 24,
    -- Late fee multiplier
    lateFeeMultiplier = 1.5,
    -- Max unpaid tickets before impound risk
    maxUnpaidTickets = 5,
    -- Jobs that can issue tickets
    authorizedJobs = { 'police', 'sheriff', 'parking_enforcement' },
}

-- ============================================
-- TICKET OPERATIONS
-- ============================================

---Issue a parking ticket
---@param source number|nil Officer source (nil for automated)
---@param plate string
---@param violationType string
---@param location vector3|nil
---@param notes string|nil
---@return boolean success
---@return string message
function Violations.IssueTicket(source, plate, violationType, location, notes)
    -- Check permission if issued by officer (not automated)
    if source then
        local canTicket, permReason = Permissions.Check(source, 'issueTicket')
        if not canTicket then
            return false, permReason
        end
    end

    local ticketType = Violations.Config.types[violationType]
    if not ticketType then
        return false, 'Invalid violation type'
    end

    -- Get vehicle owner
    local tbl = Bridge.DB.GetVehicleTable()
    local owner = Bridge.DB.GetOwnerColumn()

    local result = MySQL.query.await(
        ('SELECT %s FROM %s WHERE plate = ?'):format(owner, tbl),
        {plate}
    )

    local citizenid = result and result[1] and result[1][owner] or nil

    -- Create ticket
    local ticketId = 'TKT_' .. os.time() .. '_' .. math.random(1000, 9999)

    local ticket = {
        id = ticketId,
        plate = plate,
        citizenid = citizenid,
        type = violationType,
        typeLabel = ticketType.label,
        fine = ticketType.fine,
        points = ticketType.points,
        issuedAt = os.time(),
        issuedBy = source and Bridge.GetPlayerName(source) or 'Automated System',
        location = location,
        notes = notes,
        status = 'unpaid',  -- unpaid, paid, contested, dismissed
        paidAt = nil,
    }

    Violations._tickets[ticketId] = ticket

    -- Save to database
    if DB and DB.AuditLog then
        DB.AuditLog('ticket_issued', citizenid, plate, ticket)
    end

    -- Create invoice through billing system
    if citizenid and Billing and Billing.IsAvailable() then
        Billing.CreateTicketInvoice(
            citizenid,
            ticketType.fine,
            ticketType.label,
            plate,
            ticketId
        )
    end

    -- Notify owner if online
    if citizenid then
        local player = Bridge.GetPlayerByCitizenId(citizenid)
        if player then
            local playerSource = Bridge.IsESX() and player.source or player.PlayerData.source
            if playerSource then
                Bridge.Notify(playerSource, ('You received a parking ticket: %s - $%d'):format(ticketType.label, ticketType.fine), 'error')
                TriggerClientEvent('dps-parking:client:receivedTicket', playerSource, ticket)
            end
        end
    end

    -- Send dispatch alert
    if Dispatch and Dispatch.IsAvailable() and location then
        Dispatch.SendParkingAlert({
            type = violationType,
            plate = plate,
            location = location,
            description = ('Ticket issued: %s - %s'):format(ticketType.label, plate),
        })
    end

    -- Publish event
    EventBus.Publish('violations:ticketIssued', {
        ticketId = ticketId,
        plate = plate,
        citizenid = citizenid,
        type = violationType,
        fine = ticketType.fine,
    })

    return true, ('Ticket issued: %s - $%d'):format(ticketType.label, ticketType.fine)
end

---Pay a parking ticket
---@param source number
---@param ticketId string
---@return boolean success
---@return string message
function Violations.PayTicket(source, ticketId)
    local citizenid = Bridge.GetCitizenId(source)
    local ticket = Violations._tickets[ticketId]

    if not ticket then
        return false, 'Ticket not found'
    end

    if ticket.citizenid ~= citizenid then
        return false, 'This is not your ticket'
    end

    if ticket.status == 'paid' then
        return false, 'Ticket already paid'
    end

    if ticket.status == 'dismissed' then
        return false, 'Ticket was dismissed'
    end

    -- Calculate fine with late fee
    local fine = ticket.fine
    local hoursSinceIssued = (os.time() - ticket.issuedAt) / 3600

    if hoursSinceIssued > Violations.Config.gracePeriodHours then
        fine = math.floor(fine * Violations.Config.lateFeeMultiplier)
    end

    -- Check funds
    if Bridge.GetMoney(source, 'bank') < fine then
        if Bridge.GetMoney(source, 'cash') < fine then
            return false, L('insufficient_funds', Utils.FormatMoney(fine))
        end
    end

    -- Charge
    if Bridge.GetMoney(source, 'bank') >= fine then
        Bridge.RemoveMoney(source, 'bank', fine, 'Parking ticket payment')
    else
        Bridge.RemoveMoney(source, 'cash', fine, 'Parking ticket payment')
    end

    -- Update ticket
    ticket.status = 'paid'
    ticket.paidAt = os.time()
    ticket.paidAmount = fine

    EventBus.Publish('violations:ticketPaid', {
        ticketId = ticketId,
        citizenid = citizenid,
        amount = fine,
    })

    return true, ('Ticket paid: $%d'):format(fine)
end

---Contest a parking ticket
---@param source number
---@param ticketId string
---@param reason string
---@return boolean success
---@return string message
function Violations.ContestTicket(source, ticketId, reason)
    local citizenid = Bridge.GetCitizenId(source)
    local ticket = Violations._tickets[ticketId]

    if not ticket then
        return false, 'Ticket not found'
    end

    if ticket.citizenid ~= citizenid then
        return false, 'This is not your ticket'
    end

    if ticket.status ~= 'unpaid' then
        return false, 'Ticket cannot be contested'
    end

    ticket.status = 'contested'
    ticket.contestReason = reason
    ticket.contestedAt = os.time()

    EventBus.Publish('violations:ticketContested', {
        ticketId = ticketId,
        citizenid = citizenid,
        reason = reason,
    })

    return true, 'Ticket contested - awaiting review'
end

---Dismiss a ticket (admin/judge)
---@param source number
---@param ticketId string
---@param reason string
---@return boolean success
---@return string message
function Violations.DismissTicket(source, ticketId, reason)
    if not Bridge.IsAdmin(source) then
        -- Check for judge job
        local job = Bridge.GetPlayerJob(source)
        if job ~= 'judge' and job ~= 'lawyer' then
            return false, 'Not authorized'
        end
    end

    local ticket = Violations._tickets[ticketId]
    if not ticket then
        return false, 'Ticket not found'
    end

    ticket.status = 'dismissed'
    ticket.dismissedBy = Bridge.GetPlayerName(source)
    ticket.dismissReason = reason

    -- Notify owner
    if ticket.citizenid then
        local player = Bridge.GetPlayerByCitizenId(ticket.citizenid)
        if player then
            local playerSource = Bridge.IsESX() and player.source or player.PlayerData.source
            if playerSource then
                Bridge.Notify(playerSource, 'Your parking ticket has been dismissed', 'success')
            end
        end
    end

    return true, 'Ticket dismissed'
end

---Get player's tickets
---@param citizenid string
---@return table tickets
function Violations.GetPlayerTickets(citizenid)
    local tickets = {}

    for id, ticket in pairs(Violations._tickets) do
        if ticket.citizenid == citizenid then
            local fine = ticket.fine
            local hoursSinceIssued = (os.time() - ticket.issuedAt) / 3600

            if hoursSinceIssued > Violations.Config.gracePeriodHours and ticket.status == 'unpaid' then
                fine = math.floor(fine * Violations.Config.lateFeeMultiplier)
            end

            table.insert(tickets, {
                id = id,
                plate = ticket.plate,
                type = ticket.typeLabel,
                fine = fine,
                originalFine = ticket.fine,
                status = ticket.status,
                issuedAt = ticket.issuedAt,
                isLate = hoursSinceIssued > Violations.Config.gracePeriodHours,
            })
        end
    end

    return tickets
end

---Count unpaid tickets for player
---@param citizenid string
---@return number count
function Violations.CountUnpaidTickets(citizenid)
    local count = 0
    for _, ticket in pairs(Violations._tickets) do
        if ticket.citizenid == citizenid and ticket.status == 'unpaid' then
            count = count + 1
        end
    end
    return count
end

-- ============================================
-- AUTOMATED VIOLATIONS
-- ============================================

-- Check for expired meters and issue tickets
EventBus.Subscribe('meters:expired', function(data)
    if not Config.Violations or not Config.Violations.autoTicket then return end

    Violations.IssueTicket(nil, data.plate, 'expired_meter', nil, 'Automated: Meter expired')
end, EventBus.Priority.NORMAL)

-- Check for no-parking zone violations
EventBus.Subscribe('zones:violation', function(data)
    if not Config.Violations or not Config.Violations.autoTicket then return end

    local violationType = data.zoneType or 'no_parking'
    Violations.IssueTicket(nil, data.plate, violationType, data.location, 'Automated: Zone violation')
end, EventBus.Priority.NORMAL)

-- ============================================
-- EVENTS
-- ============================================

RegisterNetEvent('dps-parking:server:issueTicket', function(plate, violationType, notes)
    local source = source

    -- Check authorization
    local job = Bridge.GetPlayerJob(source)
    local authorized = false
    for _, j in ipairs(Violations.Config.authorizedJobs) do
        if job == j then authorized = true break end
    end

    if not authorized then
        Bridge.Notify(source, 'Not authorized to issue tickets', 'error')
        return
    end

    local success, message = Violations.IssueTicket(source, plate, violationType, nil, notes)
    Bridge.Notify(source, message, success and 'success' or 'error')
end)

RegisterNetEvent('dps-parking:server:payTicket', function(ticketId)
    local source = source
    local success, message = Violations.PayTicket(source, ticketId)
    Bridge.Notify(source, message, success and 'success' or 'error')
end)

RegisterNetEvent('dps-parking:server:contestTicket', function(ticketId, reason)
    local source = source
    local success, message = Violations.ContestTicket(source, ticketId, reason)
    Bridge.Notify(source, message, success and 'success' or 'error')
end)

-- Callbacks
Bridge.CreateCallback('dps-parking:server:getMyTickets', function(source, cb)
    local citizenid = Bridge.GetCitizenId(source)
    cb(Violations.GetPlayerTickets(citizenid))
end)

print('^2[DPS-Parking] Violations module (server) loaded^0')

return Violations
