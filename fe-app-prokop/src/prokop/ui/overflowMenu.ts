export interface OverflowMenuItem {
  label: string;
  onClick: () => void;
  danger?: boolean;
  disabled?: boolean;
}

// Rare actions live behind one "⋯" button instead of a row of equal
// buttons. A native <details> keeps it keyboard accessible.
export function renderOverflowMenu(label: string, items: OverflowMenuItem[]) {
  const menu = E('details', { class: 'fkp-menu' }) as HTMLDetailsElement;
  const close = () => {
    menu.open = false;
  };

  menu.appendChild(
    E(
      'summary',
      {
        class: 'btn cbi-button fkp-menu__toggle',
        title: label,
        'aria-label': label,
      },
      '⋯',
    ),
  );
  menu.appendChild(
    E(
      'div',
      { class: 'fkp-menu__list', role: 'menu' },
      items.map((item) =>
        E(
          'button',
          {
            type: 'button',
            role: 'menuitem',
            class: `fkp-menu__item${item.danger ? ' fkp-action-danger-text' : ''}`,
            disabled: item.disabled ? true : undefined,
            click: () => {
              close();
              item.onClick();
            },
          },
          item.label,
        ),
      ),
    ),
  );

  registerOutsideClose();
  return menu;
}

// One document listener for every menu: menus are re-rendered with the data
// they belong to, so a listener per menu would pile up.
let outsideCloseRegistered = false;

function registerOutsideClose() {
  if (outsideCloseRegistered || typeof document === 'undefined') return;
  if (!document.addEventListener) return;
  outsideCloseRegistered = true;
  document.addEventListener('click', (event) => {
    document
      .querySelectorAll<HTMLDetailsElement>('details.fkp-menu[open]')
      .forEach((menu) => {
        if (!menu.contains(event.target as Node)) menu.open = false;
      });
  });
}
