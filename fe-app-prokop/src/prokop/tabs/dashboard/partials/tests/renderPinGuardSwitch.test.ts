import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  collectInnerHtml,
  collectText,
  luciE,
} from '../../../../../helpers/tests/luciDom';
import { renderPinGuardSwitch } from '../renderSections';

vi.mock('../../../../../icons', () => ({
  renderLoaderCircleIcon24: () => '',
  renderInfoIcon24: () => '',
}));
vi.mock('../../../../../helpers', () => ({ svgEl: () => '' }));

afterEach(() => vi.unstubAllGlobals());

// R2: the dashboard says that the pin guard moved a rule off the server
// chosen by hand, with names a subscription controls handed over as text.
describe('pin guard notice', () => {
  it('names the server, the group and the time as text', () => {
    vi.stubGlobal('E', luciE);
    const rendered = renderPinGuardSwitch({
      fromName: '<b>Dead</b> %s node',
      toName: 'Fastest',
      time: 1_760_000_000,
    });

    expect(collectInnerHtml(rendered).filter((v) => v.includes('<'))).toEqual(
      [],
    );
    const text = collectText(rendered);
    expect(text).toContain('Server <b>Dead</b> %s node did not answer');
    expect(text).toContain('switched this rule to Fastest at ');
    expect(text).not.toContain('at %s');
  });

  it('leaves out the time it does not know and renders nothing without a switch', () => {
    vi.stubGlobal('E', luciE);
    const text = collectText(
      renderPinGuardSwitch({ fromName: 'A', toName: 'B', time: 0 }),
    );
    expect(text).toContain('switched this rule to B. Choose the server again');
    expect(renderPinGuardSwitch(undefined)).toBeUndefined();
  });
});
