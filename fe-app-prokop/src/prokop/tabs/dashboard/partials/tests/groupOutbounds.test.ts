import { describe, expect, it } from 'vitest';
import { groupOutbounds } from '../groupOutbounds';
describe('outbound grouping', () => {
  it('keeps node identities and selection in stable country groups', () => {
    const nodes = [
      { displayName: '🇩🇪 Berlin', selected: true },
      { displayName: 'Paris', country: 'fr' },
      { displayName: '🇩🇪 Frankfurt' },
      { displayName: 'Custom' },
    ];
    const groups = groupOutbounds(nodes, 'country');
    expect([...groups.keys()]).toEqual(['DE', 'FR', 'Other']);
    expect(groups.get('DE')).toEqual([nodes[0], nodes[2]]);
    expect(groups.get('DE')?.[0]).toBe(nodes[0]);
  });
  it('groups named subscription prefixes without rewriting names', () => {
    expect([
      ...groupOutbounds(
        [
          { displayName: '🇫🇷 Europe | Paris' },
          { displayName: 'Europe | Berlin' },
          { displayName: 'Home' },
        ],
        'prefix',
      ).keys(),
    ]).toEqual(['Europe', 'Home']);
  });
});
