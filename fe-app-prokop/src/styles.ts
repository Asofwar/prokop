// language=CSS
import { DashboardTab } from './prokop/tabs/dashboard';
import { DiagnosticTab } from './prokop/tabs/diagnostic';
import { MonitoringTab } from './prokop/tabs/monitoring';
import { UpdatesTab } from './prokop/tabs/updates';
import { HistoryTab } from './prokop/tabs/history';
import { AutotuneTab } from './prokop/tabs/autotune';
import { PartialStyles } from './partials';
import { BREAKPOINTS, FoundationStyles } from './prokop/ui';
import { PROKOP_UCI_PACKAGE as PROKOP_CBI_PREFIX } from './constants';

export const GlobalStyles = `
${FoundationStyles}
${DashboardTab.styles}
${DiagnosticTab.styles}
${MonitoringTab.styles}
${UpdatesTab.styles}
${HistoryTab.styles}
${AutotuneTab.styles}
${PartialStyles}


/* Hide extra H3 for settings tab */
#cbi-${PROKOP_CBI_PREFIX}-settings > h3 {
    display: none;
}

/* Hide extra H3 for rules tab */
#cbi-${PROKOP_CBI_PREFIX}-section > h3:nth-child(1) {
    display: none;
}

/* Vertical align for remove rule action button */
#cbi-${PROKOP_CBI_PREFIX}-section > .cbi-section-remove {
    margin-bottom: -32px;
}

#cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-actions > div {
    display: inline-flex;
    align-items: center;
    gap: 4px;
}

#cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-actions {
    text-align: right;
}

/* Narrow screens: the row actions wrap and the fixed column widths go,
   so the rules table fits the page at 768 (UC-132). */
@media (max-width: ${BREAKPOINTS.narrow}px) {
    #cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-actions {
        white-space: normal;
    }

    #cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-actions > div {
        flex-wrap: wrap;
        justify-content: flex-end;
    }

    #cbi-${PROKOP_CBI_PREFIX}-section .th,
    #cbi-${PROKOP_CBI_PREFIX}-section .td {
        width: auto !important;
    }
}

/* Rule reorder visuals */
#cbi-${PROKOP_CBI_PREFIX}-section {
    position: relative;
}

#cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-table-row {
    position: relative;
}

#cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-table-row.placeholder {
    opacity: 1;
}

#cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-table-row.placeholder em {
    font-style: italic;
}

#cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-table-row.drag-over-above::after,
#cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-table-row.drag-over-below::after {
    content: '';
    position: absolute;
    left: 10px;
    right: 10px;
    height: 2px;
    border-radius: 2px;
    background: var(--primary-color-high, #1976d2);
    pointer-events: none;
    z-index: 2;
}

#cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-table-row.drag-over-above::after {
    top: -1px;
}

#cbi-${PROKOP_CBI_PREFIX}-section .cbi-section-table-row.drag-over-below::after {
    bottom: -1px;
}

/* Centered class helper */
.centered {
    display: flex;
    align-items: center;
    justify-content: center;
}

/* Rotate class helper */
.rotate {
    animation: spin 1s linear infinite;
}

@keyframes spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
}

/* Skeleton styles*/
.skeleton {
    background-color: var(--background-color-low, #e0e0e0);
    border-radius: 4px;
    position: relative;
    overflow: hidden;
}

.skeleton::after {
    content: '';
    position: absolute;
    top: 0;
    left: -150%;
    width: 150%;
    height: 100%;
    background: linear-gradient(
            90deg,
            transparent,
            rgba(255, 255, 255, 0.4),
            transparent
    );
    animation: skeleton-shimmer 1.6s infinite;
}

@keyframes skeleton-shimmer {
    100% {
        left: 150%;
    }
}
/* Toast */
.toast-container {
    position: fixed;
    bottom: 30px;
    left: 50%;
    transform: translateX(-50%);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 10px;
    z-index: 9999;
    font-family: system-ui, sans-serif;
}

.toast {
    opacity: 0;
    transform: translateY(10px);
    transition: opacity 0.3s ease, transform 0.3s ease;
    padding: 10px 16px;
    border-radius: 6px;
    color: #fff;
    font-size: 14px;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.2);
    min-width: 220px;
    max-width: 340px;
    text-align: center;
}

.toast-success {
    background-color: #1e7e34;
}

.toast-error {
    background-color: #dc3545;
}

.toast-warning {
    background-color: #b26a00;
}

.toast-info {
    background-color: #1565c0;
}

.toast.visible {
    opacity: 1;
    transform: translateY(0);
}
`;
