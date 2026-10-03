import { describe, expect, it } from 'vitest';

import { DOMAIN_LIST_OPTIONS, domainListLabel } from '../../../../constants';
import { DIAGNOSTICS_CHECKS_MAP } from '../checks/contstants';

describe('whole translatable phrases', () => {
  it('names every diagnostic check with its own phrase', () => {
    const titles = Object.values(DIAGNOSTICS_CHECKS_MAP).map((c) => c.title);
    expect(titles).toContain('DNS checks');
    expect(titles).toContain('sing-box checks');
    expect(titles).toContain('Outbound checks');
    expect(titles.every((title) => / checks$/.test(title))).toBe(true);
  });

  it('gives every built-in list a name', () => {
    expect(domainListLabel('russia_inside')).toBe('Russia: blocked inside');
    expect(domainListLabel('youtube')).toBe('Youtube');
    for (const key of Object.keys(DOMAIN_LIST_OPTIONS))
      expect(domainListLabel(key)).toBeTruthy();
    expect(domainListLabel('custom_list')).toBe('custom_list');
  });
});
