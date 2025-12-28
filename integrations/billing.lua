--[[
    DPS-Parking - Billing Integration
    Original: mh-parking by MaDHouSe79
    Enhanced: DPS Development

    Integration with billing systems for parking tickets:
    - qs-billing (primary)
    - qb-billing
    - esx_billing

    Tickets create invoices instead of direct payment.
    Players pay at city hall or through phone.
]]

Billing = {}

-- Detected billing script
Billing._script = nil

-- Society account for parking fines
Billing.Config = {
    -- Society/account that receives parking fine money
    societyAccount = 'government',  -- or 'police', 'cityhall'
    -- Fallback: direct payment if no billing system
    allowDirectPayment = true,
    -- Invoice settings
    invoiceLabel = 'City of Los Santos - Parking Division',
    invoiceDueDays = 7,  -- Days before late fee
}

-- ============================================
-- DETECTION
-- ============================================

---Detect which billing script is running
---@return string|nil
function Billing.Detect()
    if Billing._script then
        return Billing._script
    end

    local scripts = {
        'qs-billing',
        'qb-billing',
        'esx_billing',
        'okokBilling',
        'renewed-banking',  -- Has billing
    }

    for _, script in ipairs(scripts) do
        if GetResourceState(script) == 'started' then
            Billing._script = script
            return script
        end
    end

    return nil
end

---Check if billing is available
---@return boolean
function Billing.IsAvailable()
    return Billing.Detect() ~= nil
end

-- ============================================
-- INVOICE CREATION
-- ============================================

---Create a parking ticket invoice
---@param citizenid string Player who receives the invoice
---@param amount number Fine amount
---@param reason string Ticket reason/description
---@param plate string Vehicle plate
---@param ticketId string Ticket ID for reference
---@return boolean success
---@return string message
function Billing.CreateTicketInvoice(citizenid, amount, reason, plate, ticketId)
    local script = Billing.Detect()

    -- Build invoice description
    local description = ('Parking Violation\n%s\nPlate: %s\nTicket #: %s'):format(
        reason,
        plate,
        ticketId
    )

    if script == 'qs-billing' then
        -- QS Billing
        local success = exports['qs-billing']:CreateBillingForIdentifier(
            citizenid,                      -- Target identifier
            Billing.Config.societyAccount,  -- Society/account
            Billing.Config.invoiceLabel,    -- Sender label
            amount,                         -- Amount
            description                     -- Reason/description
        )

        if success then
            return true, 'Invoice created - check your bills'
        else
            return false, 'Failed to create invoice'
        end

    elseif script == 'qb-billing' then
        -- QB Billing (older style)
        local player = Bridge.GetPlayerByCitizenId(citizenid)
        if player then
            local playerSource = Bridge.IsESX() and player.source or player.PlayerData.source
            if playerSource then
                TriggerClientEvent('qb-billing:client:ReceiveInvoice', playerSource, {
                    sender = Billing.Config.invoiceLabel,
                    amount = amount,
                    reason = description,
                    society = Billing.Config.societyAccount,
                })
                return true, 'Invoice sent - check your bills'
            end
        end
        return false, 'Could not send invoice'

    elseif script == 'esx_billing' then
        -- ESX Billing
        TriggerEvent('esx_billing:sendBill', citizenid, Billing.Config.societyAccount, description, amount)
        return true, 'Invoice sent'

    elseif script == 'okokBilling' then
        -- OKOK Billing
        exports['okokBilling']:CreateInvoice(
            citizenid,
            amount,
            description,
            Billing.Config.societyAccount
        )
        return true, 'Invoice created'
    end

    -- No billing system - use fallback
    if Billing.Config.allowDirectPayment then
        return false, 'No billing system - direct payment required'
    end

    return false, 'Billing system unavailable'
end

---Create impound fee invoice
---@param citizenid string
---@param amount number
---@param plate string
---@param reason string
---@return boolean success
---@return string message
function Billing.CreateImpoundInvoice(citizenid, amount, plate, reason)
    local description = ('Vehicle Impound Fee\nReason: %s\nPlate: %s'):format(reason, plate)

    return Billing.CreateInvoice(citizenid, amount, description, 'impound')
end

---Create generic invoice
---@param citizenid string
---@param amount number
---@param description string
---@param type string
---@return boolean success
---@return string message
function Billing.CreateInvoice(citizenid, amount, description, invoiceType)
    local script = Billing.Detect()

    if script == 'qs-billing' then
        local success = exports['qs-billing']:CreateBillingForIdentifier(
            citizenid,
            Billing.Config.societyAccount,
            Billing.Config.invoiceLabel,
            amount,
            description
        )
        return success, success and 'Invoice created' or 'Failed to create invoice'

    elseif script == 'qb-billing' then
        local player = Bridge.GetPlayerByCitizenId(citizenid)
        if player then
            local playerSource = Bridge.IsESX() and player.source or player.PlayerData.source
            if playerSource then
                TriggerClientEvent('qb-billing:client:ReceiveInvoice', playerSource, {
                    sender = Billing.Config.invoiceLabel,
                    amount = amount,
                    reason = description,
                    society = Billing.Config.societyAccount,
                })
                return true, 'Invoice sent'
            end
        end
        return false, 'Could not send invoice'
    end

    return false, 'Billing unavailable'
end

-- ============================================
-- SOCIETY DEPOSITS
-- ============================================

---Deposit money to society account (for direct payments)
---@param amount number
---@param reason string
---@return boolean success
function Billing.DepositToSociety(amount, reason)
    local script = Billing.Detect()
    local society = Billing.Config.societyAccount

    if script == 'qs-billing' or GetResourceState('qs-banking') == 'started' then
        -- QS Banking society deposit
        exports['qs-banking']:AddMoney(society, amount, reason)
        return true

    elseif GetResourceState('qb-banking') == 'started' then
        -- QB Banking
        exports['qb-banking']:AddMoney(society, amount, reason)
        return true

    elseif GetResourceState('qb-management') == 'started' then
        -- QB Management society
        TriggerEvent('qb-bossmenu:server:addAccountMoney', society, amount)
        return true

    elseif Bridge.IsESX() then
        -- ESX society
        TriggerEvent('esx_society:getSociety', society, function(soc)
            if soc then
                TriggerEvent('esx_addonaccount:getSharedAccount', soc.account, function(account)
                    if account then
                        account.addMoney(amount)
                    end
                end)
            end
        end)
        return true
    end

    return false
end

-- ============================================
-- PAYMENT TRACKING
-- ============================================

-- Track paid invoices (optional webhook for violations module)
if GetResourceState('qs-billing') == 'started' then
    -- Hook into qs-billing payment event if available
    AddEventHandler('qs-billing:server:billPaid', function(data)
        -- Check if this was a parking ticket
        if data.reason and string.find(data.reason, 'Parking Violation') then
            EventBus.Publish('billing:ticketPaid', {
                citizenid = data.citizenid,
                amount = data.amount,
                reason = data.reason,
            })
        end
    end)
end

-- ============================================
-- INITIALIZATION
-- ============================================

CreateThread(function()
    Wait(3000)
    local script = Billing.Detect()
    if script then
        print('^2[DPS-Parking] Billing integration: hooked into ' .. script .. '^0')
    else
        print('^3[DPS-Parking] Billing integration: no billing system detected (direct payment mode)^0')
    end
end)

print('^2[DPS-Parking] Billing integration loaded^0')

return Billing
