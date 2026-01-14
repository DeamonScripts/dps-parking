/**
 * DPS Parking - Main Application
 * Handles all UI logic and NUI communication
 */

const ParkingUI = {
    // State
    isOpen: false,
    currentTab: 'vehicles',
    selectedVehicle: null,
    selectedDeliveryType: 'standard',

    // Data
    vehicles: [],
    deliveries: [],
    meters: [],
    tickets: [],
    playerData: {
        vipTier: 'standard',
        slotsUsed: 0,
        slotsMax: 5
    },

    // Config (populated from Lua)
    config: {
        deliveryPrices: {
            standard: 500,
            rush: 1000
        },
        currency: '$'
    },

    /**
     * Initialize the UI
     */
    init: function() {
        console.log('[DPS-Parking] UI Initialized');
        this.setupEventListeners();
        this.hide();
    },

    /**
     * Setup event listeners
     */
    setupEventListeners: function() {
        // Escape key to close
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && this.isOpen) {
                this.close();
            }
        });

        // Vehicle search with debounce
        const searchInput = document.getElementById('vehicle-search');
        if (searchInput) {
            searchInput.addEventListener('input', Utils.debounce(() => {
                this.filterVehicles();
            }, 300));
        }

        // NPC driver checkbox
        const npcCheckbox = document.getElementById('npc-driver');
        if (npcCheckbox) {
            npcCheckbox.addEventListener('change', () => {
                this.updateDeliverySummary();
            });
        }
    },

    /**
     * Open the parking UI
     * @param {object} data - Initial data from Lua
     */
    open: function(data) {
        if (data) {
            this.vehicles = data.vehicles || [];
            this.deliveries = data.deliveries || [];
            this.meters = data.meters || [];
            this.tickets = data.tickets || [];
            this.playerData = data.playerData || this.playerData;
            this.config = data.config || this.config;
        }

        this.isOpen = true;
        this.updateHeader();
        this.updateAllTabs();
        this.switchTab('vehicles');

        const app = document.getElementById('parking-app');
        app.classList.remove('hidden');
        Utils.animateIn(app.querySelector('.dashboard'), 'scaleIn');

        Utils.playSound('open');
    },

    /**
     * Close the parking UI
     */
    close: function() {
        this.isOpen = false;
        this.closeModal();
        this.closeDeliveryModal();

        const app = document.getElementById('parking-app');
        app.classList.add('hidden');

        Utils.nuiCallback('close');
        Utils.playSound('close');
    },

    /**
     * Hide UI without callback
     */
    hide: function() {
        document.getElementById('parking-app').classList.add('hidden');
        document.getElementById('vehicle-modal').classList.add('hidden');
        document.getElementById('delivery-modal').classList.add('hidden');
    },

    /**
     * Update header stats
     */
    updateHeader: function() {
        const tierInfo = Utils.getVIPTierInfo(this.playerData.vipTier);

        // VIP Badge
        const vipBadge = document.getElementById('vip-badge');
        const vipTier = document.getElementById('vip-tier');
        if (vipBadge && vipTier) {
            vipTier.textContent = tierInfo.label;
            vipBadge.style.setProperty('--tier-color', tierInfo.color);
            vipBadge.querySelector('i').className = 'fas ' + tierInfo.icon;
        }

        // Slot count
        const slotCount = document.getElementById('slot-count');
        if (slotCount) {
            slotCount.textContent = this.playerData.slotsUsed + '/' + this.playerData.slotsMax;
        }
    },

    /**
     * Switch between tabs
     * @param {string} tab - Tab name
     */
    switchTab: function(tab) {
        this.currentTab = tab;

        // Update tab buttons
        document.querySelectorAll('.nav-tab').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.tab === tab);
        });

        // Update tab content
        document.querySelectorAll('.tab-content').forEach(content => {
            content.classList.toggle('active', content.id === 'tab-' + tab);
        });

        Utils.playSound('click');
    },

    /**
     * Update all tab contents
     */
    updateAllTabs: function() {
        this.renderVehicles();
        this.renderDeliveries();
        this.renderMeters();
        this.renderTickets();
        this.updateBadges();
    },

    /**
     * Update notification badges
     */
    updateBadges: function() {
        // Delivery badge
        const deliveryBadge = document.getElementById('delivery-count');
        if (deliveryBadge) {
            const count = this.deliveries.length;
            deliveryBadge.textContent = count;
            deliveryBadge.classList.toggle('hidden', count === 0);
        }

        // Ticket badge
        const ticketBadge = document.getElementById('ticket-count');
        if (ticketBadge) {
            const count = this.tickets.filter(t => !t.paid).length;
            ticketBadge.textContent = count;
            ticketBadge.classList.toggle('hidden', count === 0);
        }
    },

    /**
     * Render vehicles grid
     */
    renderVehicles: function() {
        const container = document.getElementById('vehicle-list');
        const emptyState = document.getElementById('empty-vehicles');

        if (!this.vehicles.length) {
            container.innerHTML = '';
            emptyState.classList.remove('hidden');
            return;
        }

        emptyState.classList.add('hidden');
        container.innerHTML = this.vehicles.map(vehicle => this.createVehicleCard(vehicle)).join('');
    },

    /**
     * Create vehicle card HTML
     * @param {object} vehicle - Vehicle data
     * @returns {string} HTML string
     */
    createVehicleCard: function(vehicle) {
        const fuel = vehicle.fuel || 100;
        const body = vehicle.body || 100;
        const engine = vehicle.engine || 100;

        return `
            <div class="vehicle-card" onclick="ParkingUI.selectVehicle('${Utils.escapeHtml(vehicle.plate)}')">
                <div class="vehicle-card-header">
                    <div class="vehicle-plate">${Utils.escapeHtml(Utils.formatPlate(vehicle.plate))}</div>
                    <div class="vehicle-class">
                        <i class="${Utils.getVehicleIcon(vehicle.class)}"></i>
                    </div>
                </div>
                <div class="vehicle-card-body">
                    <div class="vehicle-model">${Utils.escapeHtml(Utils.capitalize(vehicle.model || 'Unknown'))}</div>
                    <div class="vehicle-location">
                        <i class="fas fa-map-marker-alt"></i>
                        ${Utils.escapeHtml(vehicle.location || 'Unknown Location')}
                    </div>
                    <div class="vehicle-time">
                        <i class="fas fa-clock"></i>
                        ${Utils.formatTimeAgo(vehicle.parkedAt || 0)}
                    </div>
                </div>
                <div class="vehicle-card-footer">
                    <div class="mini-stats">
                        <div class="mini-stat ${Utils.getFuelClass(fuel)}">
                            <i class="fas fa-gas-pump"></i>
                            <span>${Math.round(fuel)}%</span>
                        </div>
                        <div class="mini-stat ${Utils.getHealthClass(body)}">
                            <i class="fas fa-car-crash"></i>
                            <span>${Math.round(body)}%</span>
                        </div>
                        <div class="mini-stat ${Utils.getHealthClass(engine)}">
                            <i class="fas fa-cogs"></i>
                            <span>${Math.round(engine)}%</span>
                        </div>
                    </div>
                </div>
            </div>
        `;
    },

    /**
     * Filter vehicles by search
     */
    filterVehicles: function() {
        const search = document.getElementById('vehicle-search')?.value?.toLowerCase() || '';

        if (!search) {
            this.renderVehicles();
            return;
        }

        const filtered = this.vehicles.filter(v =>
            v.plate?.toLowerCase().includes(search) ||
            v.model?.toLowerCase().includes(search)
        );

        const container = document.getElementById('vehicle-list');
        const emptyState = document.getElementById('empty-vehicles');

        if (!filtered.length) {
            container.innerHTML = '<div class="no-results"><i class="fas fa-search"></i><p>No vehicles found</p></div>';
            emptyState.classList.add('hidden');
            return;
        }

        emptyState.classList.add('hidden');
        container.innerHTML = filtered.map(vehicle => this.createVehicleCard(vehicle)).join('');
    },

    /**
     * Select a vehicle and open detail modal
     * @param {string} plate - Vehicle plate
     */
    selectVehicle: function(plate) {
        this.selectedVehicle = this.vehicles.find(v => v.plate === plate);

        if (!this.selectedVehicle) return;

        // Populate modal
        document.getElementById('modal-plate').textContent = Utils.formatPlate(this.selectedVehicle.plate);
        document.getElementById('modal-model').textContent = Utils.capitalize(this.selectedVehicle.model || 'Unknown');
        document.getElementById('modal-location').textContent = this.selectedVehicle.location || 'Unknown';
        document.getElementById('modal-time').textContent = Utils.formatTimeAgo(this.selectedVehicle.parkedAt || 0);

        // Update stat bars
        document.getElementById('modal-fuel').style.width = (this.selectedVehicle.fuel || 100) + '%';
        document.getElementById('modal-body').style.width = (this.selectedVehicle.body || 100) + '%';
        document.getElementById('modal-engine').style.width = (this.selectedVehicle.engine || 100) + '%';

        // Show modal
        const modal = document.getElementById('vehicle-modal');
        modal.classList.remove('hidden');
        Utils.animateIn(modal.querySelector('.modal-content'), 'scaleIn');

        Utils.playSound('click');
    },

    /**
     * Close vehicle modal
     */
    closeModal: function() {
        document.getElementById('vehicle-modal').classList.add('hidden');
        this.selectedVehicle = null;
    },

    /**
     * Request delivery for selected vehicle
     */
    requestDelivery: function() {
        if (!this.selectedVehicle) return;

        this.closeModal();
        this.selectedDeliveryType = 'standard';

        // Update prices
        document.getElementById('standard-price').textContent = Utils.formatMoney(this.config.deliveryPrices.standard);
        document.getElementById('rush-price').textContent = Utils.formatMoney(this.config.deliveryPrices.rush);

        // Reset selection
        document.querySelectorAll('.delivery-option').forEach(opt => {
            opt.classList.toggle('selected', opt.dataset.type === 'standard');
        });

        // Check NPC driver availability
        const npcCheckbox = document.getElementById('npc-driver');
        const tierLevel = ['standard', 'bronze', 'silver', 'gold', 'platinum', 'diamond'].indexOf(this.playerData.vipTier?.toLowerCase());
        npcCheckbox.disabled = tierLevel < 2; // Silver and above
        npcCheckbox.checked = false;

        this.updateDeliverySummary();

        // Show modal
        const modal = document.getElementById('delivery-modal');
        modal.classList.remove('hidden');
        Utils.animateIn(modal.querySelector('.modal-content'), 'scaleIn');
    },

    /**
     * Select delivery type
     * @param {string} type - Delivery type (standard/rush)
     */
    selectDeliveryType: function(type) {
        this.selectedDeliveryType = type;

        document.querySelectorAll('.delivery-option').forEach(opt => {
            opt.classList.toggle('selected', opt.dataset.type === type);
        });

        this.updateDeliverySummary();
        Utils.playSound('click');
    },

    /**
     * Update delivery summary with prices
     */
    updateDeliverySummary: function() {
        const basePrice = this.config.deliveryPrices[this.selectedDeliveryType] || 500;
        const discount = Utils.getVIPDiscount(this.playerData.vipTier);
        const discountAmount = Math.floor(basePrice * discount);
        const total = basePrice - discountAmount;

        document.getElementById('delivery-fee').textContent = Utils.formatMoney(basePrice);

        const discountRow = document.getElementById('discount-row');
        if (discount > 0) {
            discountRow.style.display = 'flex';
            document.getElementById('discount-amount').textContent = '-' + Utils.formatMoney(discountAmount);
        } else {
            discountRow.style.display = 'none';
        }

        document.getElementById('delivery-total').textContent = Utils.formatMoney(total);
    },

    /**
     * Confirm delivery request
     */
    confirmDelivery: function() {
        if (!this.selectedVehicle) return;

        const npcDriver = document.getElementById('npc-driver')?.checked || false;

        Utils.nuiCallback('requestDelivery', {
            plate: this.selectedVehicle.plate,
            type: this.selectedDeliveryType,
            npcDriver: npcDriver
        });

        this.closeDeliveryModal();
        this.showToast('Delivery requested!', 'success');
    },

    /**
     * Close delivery modal
     */
    closeDeliveryModal: function() {
        document.getElementById('delivery-modal').classList.add('hidden');
    },

    /**
     * View vehicle on map
     */
    viewOnMap: function() {
        if (!this.selectedVehicle) return;

        Utils.nuiCallback('viewOnMap', {
            plate: this.selectedVehicle.plate
        });

        this.close();
    },

    /**
     * Render deliveries list
     */
    renderDeliveries: function() {
        const container = document.getElementById('delivery-list');
        const emptyState = document.getElementById('empty-deliveries');

        if (!this.deliveries.length) {
            container.innerHTML = '';
            emptyState.classList.remove('hidden');
            return;
        }

        emptyState.classList.add('hidden');
        container.innerHTML = this.deliveries.map(delivery => `
            <div class="delivery-item">
                <div class="delivery-info">
                    <div class="delivery-plate">${Utils.escapeHtml(Utils.formatPlate(delivery.plate))}</div>
                    <div class="delivery-status ${delivery.status}">${Utils.capitalize(delivery.status)}</div>
                </div>
                <div class="delivery-details">
                    <span><i class="fas fa-truck"></i> ${delivery.type === 'rush' ? 'Rush' : 'Standard'}</span>
                    <span><i class="fas fa-clock"></i> ${Utils.formatCountdown(delivery.eta || 0)}</span>
                </div>
                <div class="delivery-progress">
                    <div class="progress-bar">
                        <div class="progress-fill" style="width: ${delivery.progress || 0}%"></div>
                    </div>
                </div>
            </div>
        `).join('');
    },

    /**
     * Render meters list
     */
    renderMeters: function() {
        const container = document.getElementById('meter-list');
        const emptyState = document.getElementById('empty-meters');

        if (!this.meters.length) {
            container.innerHTML = '';
            emptyState.classList.remove('hidden');
            return;
        }

        emptyState.classList.add('hidden');
        container.innerHTML = this.meters.map(meter => {
            const isExpired = meter.remaining <= 0;
            const isLow = meter.remaining > 0 && meter.remaining < 300; // 5 minutes

            return `
                <div class="meter-item ${isExpired ? 'expired' : ''} ${isLow ? 'warning' : ''}">
                    <div class="meter-info">
                        <div class="meter-plate">${Utils.escapeHtml(Utils.formatPlate(meter.plate))}</div>
                        <div class="meter-location">
                            <i class="fas fa-map-marker-alt"></i>
                            ${Utils.escapeHtml(meter.location || 'Unknown')}
                        </div>
                    </div>
                    <div class="meter-time">
                        <span class="time-remaining">${Utils.formatTimeRemaining(meter.remaining)}</span>
                        ${!isExpired ? `
                            <button class="btn btn-small btn-primary" onclick="ParkingUI.addTime('${Utils.escapeHtml(meter.id)}')">
                                <i class="fas fa-plus"></i> Add Time
                            </button>
                        ` : `
                            <button class="btn btn-small btn-warning" onclick="ParkingUI.payMeter('${Utils.escapeHtml(meter.id)}')">
                                <i class="fas fa-coins"></i> Pay Now
                            </button>
                        `}
                    </div>
                </div>
            `;
        }).join('');
    },

    /**
     * Add time to a meter
     * @param {string} meterId - Meter ID
     */
    addTime: function(meterId) {
        Utils.nuiCallback('addMeterTime', { meterId: meterId });
        Utils.playSound('click');
    },

    /**
     * Pay expired meter
     * @param {string} meterId - Meter ID
     */
    payMeter: function(meterId) {
        Utils.nuiCallback('payMeter', { meterId: meterId });
        Utils.playSound('click');
    },

    /**
     * Render tickets list
     */
    renderTickets: function() {
        const container = document.getElementById('ticket-list');
        const emptyState = document.getElementById('empty-tickets');

        const unpaidTickets = this.tickets.filter(t => !t.paid);

        if (!unpaidTickets.length) {
            container.innerHTML = '';
            emptyState.classList.remove('hidden');
            return;
        }

        emptyState.classList.add('hidden');
        container.innerHTML = unpaidTickets.map(ticket => `
            <div class="ticket-item">
                <div class="ticket-info">
                    <div class="ticket-plate">${Utils.escapeHtml(Utils.formatPlate(ticket.plate))}</div>
                    <div class="ticket-reason">${Utils.escapeHtml(ticket.reason || 'Parking Violation')}</div>
                    <div class="ticket-date">
                        <i class="fas fa-calendar"></i>
                        ${Utils.formatTimeAgo(ticket.issuedAt || 0)}
                    </div>
                </div>
                <div class="ticket-amount">
                    <span class="amount">${Utils.formatMoney(ticket.amount || 0)}</span>
                    <button class="btn btn-small btn-primary" onclick="ParkingUI.payTicket('${Utils.escapeHtml(ticket.id)}')">
                        <i class="fas fa-credit-card"></i> Pay
                    </button>
                </div>
            </div>
        `).join('');
    },

    /**
     * Pay a single ticket
     * @param {string} ticketId - Ticket ID
     */
    payTicket: function(ticketId) {
        Utils.nuiCallback('payTicket', { ticketId: ticketId });
        Utils.playSound('click');
    },

    /**
     * Pay all tickets
     */
    payAllTickets: function() {
        const unpaid = this.tickets.filter(t => !t.paid);
        if (!unpaid.length) return;

        const total = unpaid.reduce((sum, t) => sum + (t.amount || 0), 0);

        Utils.nuiCallback('payAllTickets', {
            tickets: unpaid.map(t => t.id),
            total: total
        });

        Utils.playSound('click');
    },

    /**
     * Show toast notification
     * @param {string} message - Message to display
     * @param {string} type - Toast type (success, error, warning, info)
     */
    showToast: function(message, type = 'info') {
        const container = document.getElementById('toast-container');
        const toast = document.createElement('div');
        toast.className = 'toast toast-' + type;

        const icons = {
            success: 'fa-check-circle',
            error: 'fa-times-circle',
            warning: 'fa-exclamation-triangle',
            info: 'fa-info-circle'
        };

        toast.innerHTML = `
            <i class="fas ${icons[type] || icons.info}"></i>
            <span>${Utils.escapeHtml(message)}</span>
        `;

        container.appendChild(toast);
        Utils.animateIn(toast, 'slideUp');

        setTimeout(() => {
            toast.style.animation = 'fadeOut 0.3s ease-out forwards';
            setTimeout(() => toast.remove(), 300);
        }, 3000);
    },

    /**
     * Update delivery progress
     * @param {object} data - Delivery update data
     */
    updateDeliveryProgress: function(data) {
        const delivery = this.deliveries.find(d => d.plate === data.plate);
        if (delivery) {
            delivery.progress = data.progress;
            delivery.eta = data.eta;
            delivery.status = data.status;
            this.renderDeliveries();
            this.updateBadges();
        }
    },

    /**
     * Handle delivery completion
     * @param {object} data - Completion data
     */
    deliveryComplete: function(data) {
        this.deliveries = this.deliveries.filter(d => d.plate !== data.plate);
        this.renderDeliveries();
        this.updateBadges();
        this.showToast('Vehicle delivered!', 'success');
    },

    /**
     * Update meter time
     * @param {object} data - Meter update data
     */
    updateMeterTime: function(data) {
        const meter = this.meters.find(m => m.id === data.meterId);
        if (meter) {
            meter.remaining = data.remaining;
            this.renderMeters();
        }
    },

    /**
     * Refresh all data from server
     */
    refresh: function() {
        Utils.nuiCallback('refresh');
    }
};

// NUI Message Handler
window.addEventListener('message', function(event) {
    const data = event.data;

    switch (data.action) {
        case 'open':
            ParkingUI.open(data);
            break;

        case 'close':
            ParkingUI.hide();
            break;

        case 'updateVehicles':
            ParkingUI.vehicles = data.vehicles || [];
            ParkingUI.renderVehicles();
            break;

        case 'updateDeliveries':
            ParkingUI.deliveries = data.deliveries || [];
            ParkingUI.renderDeliveries();
            ParkingUI.updateBadges();
            break;

        case 'updateDeliveryProgress':
            ParkingUI.updateDeliveryProgress(data);
            break;

        case 'deliveryComplete':
            ParkingUI.deliveryComplete(data);
            break;

        case 'updateMeters':
            ParkingUI.meters = data.meters || [];
            ParkingUI.renderMeters();
            break;

        case 'updateMeterTime':
            ParkingUI.updateMeterTime(data);
            break;

        case 'updateTickets':
            ParkingUI.tickets = data.tickets || [];
            ParkingUI.renderTickets();
            ParkingUI.updateBadges();
            break;

        case 'ticketPaid':
            const ticket = ParkingUI.tickets.find(t => t.id === data.ticketId);
            if (ticket) ticket.paid = true;
            ParkingUI.renderTickets();
            ParkingUI.updateBadges();
            ParkingUI.showToast('Ticket paid!', 'success');
            break;

        case 'toast':
            ParkingUI.showToast(data.message, data.type);
            break;

        case 'updatePlayerData':
            ParkingUI.playerData = data.playerData;
            ParkingUI.updateHeader();
            break;

        case 'refresh':
            ParkingUI.vehicles = data.vehicles || ParkingUI.vehicles;
            ParkingUI.deliveries = data.deliveries || ParkingUI.deliveries;
            ParkingUI.meters = data.meters || ParkingUI.meters;
            ParkingUI.tickets = data.tickets || ParkingUI.tickets;
            ParkingUI.playerData = data.playerData || ParkingUI.playerData;
            ParkingUI.updateAllTabs();
            ParkingUI.updateHeader();
            break;
    }
});

// Initialize on DOM ready
document.addEventListener('DOMContentLoaded', function() {
    ParkingUI.init();
});

// Export for global access
window.ParkingUI = ParkingUI;
