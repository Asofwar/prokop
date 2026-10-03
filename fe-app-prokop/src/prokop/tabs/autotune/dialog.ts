const LABELABLE = new Set(['INPUT', 'SELECT', 'TEXTAREA']);
let fieldCount = 0;

// A label, its control and an optional hint for the .fkp-autotune__form
// grid. The label names the control: through 'for' on a form control, or
// through aria-labelledby on a group such as the domain picker (UC-142).
export function field(label: string, control: HTMLElement, hint?: string) {
  fieldCount += 1;
  const labelId = `fkp-autotune-label-${fieldCount}`;
  const labelAttrs: Record<string, string> = { id: labelId };

  if (LABELABLE.has(control.tagName)) {
    if (!control.id) control.id = `fkp-autotune-field-${fieldCount}`;
    labelAttrs.for = control.id;
  } else {
    control.setAttribute('role', 'group');
    control.setAttribute('aria-labelledby', labelId);
  }

  return [
    E('label', labelAttrs, label),
    control,
    ...(hint ? [E('div', { class: 'fkp-autotune__field-hint' }, hint)] : []),
  ];
}

// Cancel first in a '.right' container: LuCI's Escape handler clicks the
// first '.right > button' of the modal, so Escape cancels (UC-134).
export function modalActions(onSave: () => void, saveLabel: string) {
  return E('div', { class: 'right fkp-confirm__actions' }, [
    E(
      'button',
      { type: 'button', class: 'btn cbi-button', click: () => ui.hideModal() },
      _('Cancel'),
    ),
    E(
      'button',
      { type: 'button', class: 'btn cbi-button-action', click: onSave },
      saveLabel,
    ),
  ]);
}
