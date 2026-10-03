import { describe, expect, it, vi } from 'vitest';

// The tab entry points start services on import; only their styles matter.
vi.mock('../../tabs/dashboard', async () => ({
  DashboardTab: await import('../../tabs/dashboard/styles'),
}));
vi.mock('../../tabs/diagnostic', async () => ({
  DiagnosticTab: await import('../../tabs/diagnostic/styles'),
}));
vi.mock('../../tabs/monitoring', async () => ({
  MonitoringTab: await import('../../tabs/monitoring/styles'),
}));
vi.mock('../../tabs/updates', async () => ({
  UpdatesTab: await import('../../tabs/updates/styles'),
}));
vi.mock('../../tabs/history', async () => ({
  HistoryTab: await import('../../tabs/history/styles'),
}));
vi.mock('../../tabs/autotune', async () => ({
  AutotuneTab: await import('../../tabs/autotune/styles'),
}));
import { GlobalStyles } from '../../../styles';
import { BREAKPOINTS } from '../styles';
import { styles as updatesStyles } from '../../tabs/updates/styles';

function rule(css: string, selector: string): string {
  const start = css.indexOf(`${selector} {`);
  expect(start).toBeGreaterThanOrEqual(0);
  return css.slice(start, css.indexOf('}', start));
}

// The body of the first `@media (max-width: N px)` block that mentions the
// selector, with its braces matched.
function mediaBlock(css: string, maxWidth: number, selector: string) {
  const blocks = css
    .split(`@media (max-width: ${maxWidth}px) {`)
    .slice(1)
    .map((rest) => {
      let depth = 1;
      let end = 0;
      while (depth > 0 && end < rest.length) {
        if (rest[end] === '{') depth += 1;
        if (rest[end] === '}') depth -= 1;
        end += 1;
      }
      return rest.slice(0, end);
    });
  return blocks.find((block) => block.includes(selector)) ?? '';
}

describe('responsive styles', () => {
  it('uses only the shared breakpoint scale (UC-164)', () => {
    const widths = [
      ...GlobalStyles.matchAll(/@media[^{]*max-width:\s*(\d+)px/g),
    ].map((match) => Number(match[1]));

    expect(widths.length).toBeGreaterThan(0);
    expect(
      widths.filter(
        (width) => !(Object.values(BREAKPOINTS) as number[]).includes(width),
      ),
    ).toEqual([]);
  });

  it('shows Components in two columns at 1024 and one at 768 (UC-164)', () => {
    expect(
      mediaBlock(
        updatesStyles,
        BREAKPOINTS.medium,
        '.fkp_updates-page__components',
      ),
    ).toContain('repeat(2, minmax(0, 1fr))');
    expect(
      mediaBlock(
        updatesStyles,
        BREAKPOINTS.narrow,
        '.fkp_updates-page__components',
      ),
    ).toContain('grid-template-columns: minmax(0, 1fr)');
  });

  it('lets component button rows wrap inside the card (UC-131)', () => {
    for (const selector of [
      '.fkp_updates-page__component__actions-main',
      '.fkp_updates-page__component__variants-buttons',
      '.fkp_updates-page__component__info-row',
    ]) {
      const css = rule(updatesStyles, selector);
      expect(css).toContain('flex-wrap: wrap');
      expect(css).not.toContain('nowrap');
    }
  });

  it('wraps rule row actions on narrow screens (UC-132)', () => {
    const block = mediaBlock(
      GlobalStyles,
      BREAKPOINTS.narrow,
      '.cbi-section-actions',
    );

    expect(block).toContain('white-space: normal');
    expect(block).toContain('flex-wrap: wrap');
    expect(block).toContain('width: auto !important');
  });
});
