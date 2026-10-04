import { asText } from '../../../helpers/asText';
let nextFieldId = 0;

// One URLTest editor parameter: the label names its control (for/id), so
// screen readers announce it and a click on the label focuses the field.
// The pair stays two grid cells of .fkp_dashboard-page__urltest-details__params.
export function renderUrlTestEditorRow(label: string, control: HTMLElement) {
  if (!control.id) {
    control.id = `fkp-urltest-field-${++nextFieldId}`;
  }

  return E('div', { class: 'fkp_dashboard-page__urltest-details__param' }, [
    E('label', { for: control.id }, asText(label)),
    control,
  ]);
}
