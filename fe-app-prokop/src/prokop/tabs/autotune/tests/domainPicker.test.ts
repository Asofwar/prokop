import { describe, expect, it } from 'vitest';
import { visibleDomains } from '../domainPicker';

describe('visibleDomains', () => {
  const domains = ['a.youtube.com', 'googlevideo.com', 'youtu.be', 'ytimg.com'];

  it('shows pinned domains first, then the rest of the list', () => {
    expect(visibleDomains(domains, ['ytimg.com'], '').shown).toEqual([
      'ytimg.com',
      'a.youtube.com',
      'googlevideo.com',
      'youtu.be',
    ]);
  });

  it('keeps a pinned domain the list no longer holds', () => {
    expect(visibleDomains(domains, ['gone.example'], '').shown[0]).toBe(
      'gone.example',
    );
  });

  it('filters by the search and counts what does not fit', () => {
    expect(visibleDomains(domains, [], ' YOU ').shown).toEqual([
      'a.youtube.com',
      'youtu.be',
    ]);
    expect(visibleDomains(domains, [], '', 3)).toEqual({
      shown: ['a.youtube.com', 'googlevideo.com', 'youtu.be'],
      hidden: 1,
    });
  });
});
