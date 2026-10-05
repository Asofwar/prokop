import { BREAKPOINTS } from '../../ui/styles';

// language=CSS
import { PROKOP_UCI_PACKAGE as PROKOP_CBI_PREFIX } from '../../../constants';

export const styles = `
#cbi-${PROKOP_CBI_PREFIX}-updates-_mount_node > div {
    width: 100%;
}

#cbi-${PROKOP_CBI_PREFIX}-updates > h3 {
    display: none;
}

.fkp_updates-page {
    width: 100%;
}

.fkp_updates-page__components {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    align-items: flex-start;
    gap: 10px;
    width: 100%;
}

.fkp_updates-page__components-column {
    display: flex;
    flex-direction: column;
    gap: 10px;
    min-width: 0;
    width: 100%;
}

@media (max-width: ${BREAKPOINTS.medium}px) {
    .fkp_updates-page__components {
        grid-template-columns: repeat(2, minmax(0, 1fr));
    }
}

@media (max-width: ${BREAKPOINTS.narrow}px) {
    .fkp_updates-page__components {
        grid-template-columns: minmax(0, 1fr);
    }

    .fkp_updates-page__components-column {
        width: 100%;
        min-width: 0;
    }
}

.fkp_updates-page__component {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    min-width: 0;
    width: 100%;
    box-sizing: border-box;
}

.fkp_updates-page__component__header {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
    border-bottom: 1px var(--background-color-low, lightgray) solid;
    padding-bottom: 8px;
    margin-bottom: 2px;
}

.fkp_updates-page__component__title {
    color: var(--text-color-high);
    font-size: 16px;
    font-weight: bold;
    line-height: 1.2;
}

.fkp_updates-page__component__header-version {
    color: var(--text-color-medium, #888);
    font-size: 13px;
    font-weight: normal;
}

.fkp_updates-page__component__details {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.fkp_updates-page__component__info-row {
    display: flex;
    justify-content: flex-start;
    align-items: center;
    min-height: 24px;
    gap: 8px;
    flex-wrap: wrap;
}

.fkp_updates-page__component__info-label {
    color: var(--text-color-medium, #888);
    font-size: 12px;
}

.fkp_updates-page__component__info-value {
    color: var(--text-color-high, #000);
    font-weight: 500;
    font-size: 13px;
    text-align: left;
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    overflow-wrap: anywhere;
}

.fkp_updates-page__component__info-value--latest {
    flex-wrap: wrap;
    justify-content: flex-start;
}

.fkp_updates-page__component__release-version-link {
    color: var(--link-color, #3498db) !important;
    text-decoration: underline;
    font-weight: bold;
}

.fkp_updates-page__component__release-version-link:hover {
    color: var(--link-color-dark, #2980b9) !important;
}

.fkp_updates-page__component__actions {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-top: auto;
}

.fkp_updates-page__component__actions--with-details {
    border-top: 1px var(--background-color-low, lightgray) solid;
    padding-top: 10px;
}

.fkp_updates-page__component__actions-main {
    display: flex;
    justify-content: flex-start;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
}

.fkp_updates-page__component__variants {
    display: flex;
    flex-direction: column;
    gap: 6px;
    margin-top: 4px;
}

.fkp_updates-page__component__variants-title {
    font-size: 11px;
    font-weight: bold;
    color: var(--text-color-medium, gray);
}

.fkp_updates-page__component__variants-buttons {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
}
.fkp_component-progress {
    display: flex;
    flex-direction: column;
    gap: 6px;
    border-top: 1px var(--background-color-low, lightgray) solid;
    padding-top: 10px;
    min-width: 0;
    font-size: 12px;
}

.fkp_component-progress__summary {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 4px 10px;
}

.fkp_component-progress__title {
    color: var(--text-color-high, #000);
    font-size: 13px;
    overflow-wrap: anywhere;
}

.fkp_component-progress__title--done {
    color: var(--success-color-medium, green);
}

.fkp_component-progress__title--failed {
    color: var(--error-color-medium, red);
}

.fkp_component-progress__caption {
    color: var(--text-color-medium, #888);
    overflow-wrap: anywhere;
}

.fkp_component-progress__time {
    color: var(--text-color-medium, #888);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
}

.fkp_component-progress__download {
    color: var(--text-color-high, #000);
    overflow-wrap: anywhere;
}

.fkp_component-progress__bar {
    height: 6px;
    border-radius: 3px;
    background: var(--background-color-low, lightgray);
    overflow: hidden;
}

.fkp_component-progress__bar-fill {
    height: 100%;
    background: var(--primary-color-high, dodgerblue);
    transition: width 0.4s ease;
}

.fkp_component-progress__message {
    overflow-wrap: anywhere;
}

.fkp_component-progress__message--failed {
    color: var(--error-color-medium, red);
}

.fkp_component-progress__stages {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.fkp_component-progress__stage {
    display: flex;
    align-items: baseline;
    gap: 6px;
    min-width: 0;
}

.fkp_component-progress__mark {
    flex: 0 0 1em;
    text-align: center;
}

.fkp_component-progress__label {
    flex: 1 1 auto;
    min-width: 0;
    overflow-wrap: anywhere;
}

.fkp_component-progress__stage--done .fkp_component-progress__mark {
    color: var(--success-color-medium, green);
}

.fkp_component-progress__stage--current {
    font-weight: bold;
}

.fkp_component-progress__stage--current .fkp_component-progress__mark {
    color: var(--primary-color-high, dodgerblue);
}

.fkp_component-progress__stage--failed .fkp_component-progress__mark,
.fkp_component-progress__stage--failed .fkp_component-progress__label {
    color: var(--error-color-medium, red);
}

.fkp_component-progress__stage--pending {
    color: var(--text-color-medium, #888);
}

.fkp_component-progress__dismiss {
    align-self: flex-start;
}
`;
