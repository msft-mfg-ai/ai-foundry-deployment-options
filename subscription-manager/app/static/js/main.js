// Main JavaScript file for Subscription Manager

// HTMX configuration
document.body.addEventListener('htmx:configRequest', function(evt) {
    // Add any global headers here
    evt.detail.headers['X-Requested-With'] = 'htmx';
});

// Handle successful HTMX requests
document.body.addEventListener('htmx:afterRequest', function(evt) {
    if (evt.detail.successful) {
        // Handle successful requests
        const target = evt.detail.target;
        
        // Add fade-in animation to new content
        if (target) {
            target.classList.add('fade-in');
            setTimeout(() => target.classList.remove('fade-in'), 300);
        }
    }
});

// Handle HTMX errors
document.body.addEventListener('htmx:responseError', function(evt) {
    const status = evt.detail.xhr.status;
    let message = 'An error occurred. Please try again.';
    
    if (status === 404) {
        message = 'Resource not found.';
    } else if (status === 401) {
        message = 'Unauthorized. Please check your credentials.';
    } else if (status === 403) {
        message = 'Access forbidden.';
    } else if (status >= 500) {
        message = 'Server error. Please try again later.';
    }
    
    showToast(message, 'error');
});

// Toast notification helper
function showToast(message, type = 'success', duration = 3000) {
    const container = document.getElementById('toast-container');
    if (!container) return;
    
    const toast = document.createElement('div');
    
    // Set colors based on type
    let bgColor, textColor, iconSvg;
    switch (type) {
        case 'success':
            bgColor = 'bg-green-500';
            textColor = 'text-white';
            iconSvg = `<svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
            </svg>`;
            break;
        case 'error':
            bgColor = 'bg-red-500';
            textColor = 'text-white';
            iconSvg = `<svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>`;
            break;
        case 'warning':
            bgColor = 'bg-yellow-500';
            textColor = 'text-white';
            iconSvg = `<svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
            </svg>`;
            break;
        default:
            bgColor = 'bg-blue-500';
            textColor = 'text-white';
            iconSvg = `<svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>`;
    }
    
    toast.className = `${bgColor} ${textColor} px-4 py-3 rounded-lg shadow-lg flex items-center space-x-3 toast-enter`;
    toast.innerHTML = `
        ${iconSvg}
        <span>${message}</span>
        <button onclick="this.parentElement.remove()" class="ml-2 hover:opacity-75">
            <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
        </button>
    `;
    
    container.appendChild(toast);
    
    // Auto-remove after duration
    setTimeout(() => {
        toast.classList.remove('toast-enter');
        toast.classList.add('toast-exit');
        setTimeout(() => toast.remove(), 300);
    }, duration);
}

// Modal helpers
function openModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.classList.remove('hidden');
        document.body.classList.add('overflow-hidden');
    }
}

function closeModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.classList.add('hidden');
        document.body.classList.remove('overflow-hidden');
    }
}

// Close modal on escape key
document.addEventListener('keydown', function(evt) {
    if (evt.key === 'Escape') {
        const modals = document.querySelectorAll('[id$="-modal"]:not(.hidden)');
        modals.forEach(modal => {
            modal.classList.add('hidden');
        });
        document.body.classList.remove('overflow-hidden');
    }
});

// Edit subscription modal opener
function openEditModal(subscriptionId) {
    // This would fetch the subscription data and populate the edit form
    // For now, just show a toast
    showToast('Edit functionality coming soon', 'info');
}

// Limits modal opener
function openLimitsModal(subscriptionId) {
    // This would open a modal for editing token limits
    showToast('Limits editor coming soon', 'info');
}

// Format numbers with commas
function formatNumber(num) {
    return num.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

// Copy to clipboard helper
async function copyToClipboard(text) {
    try {
        await navigator.clipboard.writeText(text);
        showToast('Copied to clipboard!', 'success');
    } catch (err) {
        showToast('Failed to copy', 'error');
    }
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', function() {
    // Any initialization code here
    console.log('Subscription Manager loaded');
});
