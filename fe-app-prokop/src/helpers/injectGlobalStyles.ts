import { GlobalStyles } from '../styles';

const PROKOP_GLOBAL_STYLES_ID = 'prokop-global-styles';

export function injectGlobalStyles() {
  if (document.getElementById(PROKOP_GLOBAL_STYLES_ID)) {
    return;
  }

  document.head.insertAdjacentHTML(
    'beforeend',
    `
        <style id="${PROKOP_GLOBAL_STYLES_ID}">
          ${GlobalStyles}
        </style>
    `,
  );
}
