import { asText } from '../../../../helpers/asText';
import { insertIf } from '../../../../helpers';

interface IRenderSystemInfoRow {
  key: string;
  value: string;
  tag?: {
    label: string;
    kind: 'neutral' | 'warning' | 'success';
  };
}

interface IRenderSystemInfoProps {
  items: Array<IRenderSystemInfoRow>;
}

export function renderSystemInfo({ items }: IRenderSystemInfoProps) {
  return E('div', { class: 'fkp_diagnostic-page__right-bar__system-info' }, [
    E(
      'b',
      { class: 'fkp_diagnostic-page__right-bar__system-info__title' },
      _('System information'),
    ),
    ...items.map((item) => {
      const tagClass = [
        'fkp_diagnostic-page__right-bar__system-info__row__tag',
        ...insertIf(item.tag?.kind === 'neutral', [
          'fkp_diagnostic-page__right-bar__system-info__row__tag--neutral',
        ]),
        ...insertIf(item.tag?.kind === 'warning', [
          'fkp_diagnostic-page__right-bar__system-info__row__tag--warning',
        ]),
        ...insertIf(item.tag?.kind === 'success', [
          'fkp_diagnostic-page__right-bar__system-info__row__tag--success',
        ]),
      ]
        .filter(Boolean)
        .join(' ');

      return E(
        'div',
        { class: 'fkp_diagnostic-page__right-bar__system-info__row' },
        [
          E('b', {}, asText(item.key)),
          E('div', {}, [
            E('span', {}, asText(item.value)),
            E('span', { class: tagClass }, asText(item?.tag?.label)),
          ]),
        ],
      );
    }),
  ]);
}
