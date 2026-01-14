/**
 * DPS Parking - Utility Functions
 * Helper functions for the parking UI
 */

const Utils = {
    /**
     * Format currency with commas and dollar sign
     * @param {number} amount - Amount to format
     * @returns {string} Formatted currency string
     */
    formatMoney: function(amount) {
        return '$' + amount.toLocaleString('en-US');
    },

    /**
     * Format time ago from timestamp
     * @param {number} timestamp - Unix timestamp in seconds
     * @returns {string} Human readable time ago
     */
    formatTimeAgo: function(timestamp) {
        const now = Math.floor(Date.now() / 1000);
        const diff = now - timestamp;

        if (diff < 60) return 'Just now';
        if (diff < 3600) return Math.floor(diff / 60) + ' minutes ago';
        if (diff < 86400) return Math.floor(diff / 3600) + ' hours ago';
        if (diff < 604800) return Math.floor(diff / 86400) + ' days ago';
        return Math.floor(diff / 604800) + ' weeks ago';
    },

    /**
     * Format remaining time from seconds
     * @param {number} seconds - Seconds remaining
     * @returns {string} Formatted time string (MM:SS)
     */
    formatTimeRemaining: function(seconds) {
        if (seconds <= 0) return 'Expired';
        const mins = Math.floor(seconds / 60);
        const secs = seconds % 60;
        return mins + ':' + secs.toString().padStart(2, '0');
    },

    /**
     * Format countdown timer
     * @param {number} seconds - Seconds remaining
     * @returns {string} Formatted countdown
     */
    formatCountdown: function(seconds) {
        if (seconds <= 0) return 'Arriving...';
        if (seconds < 60) return seconds + 's';
        return Math.ceil(seconds / 60) + ' min';
    },

    /**
     * Get vehicle class icon
     * @param {string} vehicleClass - Vehicle class name
     * @returns {string} Font Awesome icon class
     */
    getVehicleIcon: function(vehicleClass) {
        const icons = {
            'car': 'fa-car',
            'suv': 'fa-truck',
            'motorcycle': 'fa-motorcycle',
            'boat': 'fa-ship',
            'helicopter': 'fa-helicopter',
            'plane': 'fa-plane',
            'truck': 'fa-truck-pickup',
            'van': 'fa-shuttle-van',
            'bicycle': 'fa-bicycle',
            'default': 'fa-car-side'
        };
        return 'fas ' + (icons[vehicleClass?.toLowerCase()] || icons.default);
    },

    /**
     * Get status color class
     * @param {string} status - Status string
     * @returns {string} CSS class for status color
     */
    getStatusColor: function(status) {
        const colors = {
            'active': 'status-success',
            'pending': 'status-warning',
            'expired': 'status-danger',
            'paid': 'status-success',
            'unpaid': 'status-danger',
            'inprogress': 'status-warning',
            'completed': 'status-success'
        };
        return colors[status?.toLowerCase()] || 'status-default';
    },

    /**
     * Get VIP tier info
     * @param {string} tier - VIP tier name
     * @returns {object} Tier info with color and icon
     */
    getVIPTierInfo: function(tier) {
        const tiers = {
            'standard': { color: '#9ca3af', icon: 'fa-user', label: 'Standard' },
            'bronze': { color: '#cd7f32', icon: 'fa-medal', label: 'Bronze' },
            'silver': { color: '#c0c0c0', icon: 'fa-crown', label: 'Silver' },
            'gold': { color: '#ffd700', icon: 'fa-crown', label: 'Gold' },
            'platinum': { color: '#e5e4e2', icon: 'fa-gem', label: 'Platinum' },
            'diamond': { color: '#b9f2ff', icon: 'fa-gem', label: 'Diamond' }
        };
        return tiers[tier?.toLowerCase()] || tiers.standard;
    },

    /**
     * Calculate discount based on VIP tier
     * @param {string} tier - VIP tier name
     * @returns {number} Discount percentage (0-1)
     */
    getVIPDiscount: function(tier) {
        const discounts = {
            'standard': 0,
            'bronze': 0.10,
            'silver': 0.15,
            'gold': 0.25,
            'platinum': 0.35,
            'diamond': 0.50
        };
        return discounts[tier?.toLowerCase()] || 0;
    },

    /**
     * Truncate string with ellipsis
     * @param {string} str - String to truncate
     * @param {number} maxLength - Maximum length
     * @returns {string} Truncated string
     */
    truncate: function(str, maxLength) {
        if (!str) return '';
        return str.length > maxLength ? str.substring(0, maxLength) + '...' : str;
    },

    /**
     * Capitalize first letter of each word
     * @param {string} str - String to capitalize
     * @returns {string} Capitalized string
     */
    capitalize: function(str) {
        if (!str) return '';
        return str.split(' ').map(word =>
            word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()
        ).join(' ');
    },

    /**
     * Generate unique ID
     * @returns {string} Unique identifier
     */
    generateId: function() {
        return 'id-' + Math.random().toString(36).substr(2, 9);
    },

    /**
     * Debounce function
     * @param {function} func - Function to debounce
     * @param {number} wait - Wait time in ms
     * @returns {function} Debounced function
     */
    debounce: function(func, wait) {
        let timeout;
        return function executedFunction(...args) {
            const later = () => {
                clearTimeout(timeout);
                func(...args);
            };
            clearTimeout(timeout);
            timeout = setTimeout(later, wait);
        };
    },

    /**
     * Parse vehicle plate for display
     * @param {string} plate - Vehicle plate
     * @returns {string} Formatted plate
     */
    formatPlate: function(plate) {
        if (!plate) return 'UNKNOWN';
        return plate.toUpperCase().trim();
    },

    /**
     * Get fuel status class based on level
     * @param {number} level - Fuel level (0-100)
     * @returns {string} CSS class
     */
    getFuelClass: function(level) {
        if (level >= 70) return 'fuel-high';
        if (level >= 30) return 'fuel-medium';
        return 'fuel-low';
    },

    /**
     * Get health status class based on level
     * @param {number} level - Health level (0-100)
     * @returns {string} CSS class
     */
    getHealthClass: function(level) {
        if (level >= 70) return 'health-good';
        if (level >= 30) return 'health-fair';
        return 'health-poor';
    },

    /**
     * Send NUI callback to Lua
     * @param {string} event - Event name
     * @param {object} data - Data to send
     * @returns {Promise} Response from Lua
     */
    nuiCallback: async function(event, data = {}) {
        try {
            const response = await fetch(`https://dps-parking/${event}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(data)
            });
            return await response.json();
        } catch (error) {
            console.error('NUI Callback Error:', error);
            return null;
        }
    },

    /**
     * Play UI sound
     * @param {string} sound - Sound name
     */
    playSound: function(sound) {
        Utils.nuiCallback('playSound', { sound: sound });
    },

    /**
     * Animate element entrance
     * @param {HTMLElement} element - Element to animate
     * @param {string} animation - Animation class name
     */
    animateIn: function(element, animation = 'fadeIn') {
        element.style.animation = 'none';
        element.offsetHeight; // Trigger reflow
        element.style.animation = animation + ' 0.3s ease-out forwards';
    },

    /**
     * Escape HTML to prevent XSS
     * @param {string} str - String to escape
     * @returns {string} Escaped string
     */
    escapeHtml: function(str) {
        if (!str) return '';
        const div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    }
};

// Export for use
window.Utils = Utils;
