import { describe, expect, it } from 'vitest';
import { asText } from '../asText';
import { collectInnerHtml, collectText, luciE } from './luciDom';

describe('asText', () => {
  it('turns a string into a text child that LuCI does not parse', () => {
    const payload = '<img src=x onerror=alert(1)>';
    const element = luciE('div', {}, asText(payload));

    expect(collectInnerHtml(element)).toEqual([]);
    expect(collectText(element)).toBe(payload);
  });

  it('keeps nodes, drops null and undefined, stringifies numbers', () => {
    const child = luciE('b', {}, ['x']) as unknown as Node;

    expect(asText(child)).toEqual([child]);
    expect(asText(null)).toEqual([]);
    expect(asText(undefined)).toEqual([]);
    expect(asText(42)).toEqual(['42']);
    expect(asText(['a', null, child])).toEqual(['a', child]);
  });

  it('shows why the wrapper exists: a bare string becomes innerHTML', () => {
    const element = luciE('div', {}, '<b>x</b>');

    expect(collectInnerHtml(element)).toEqual(['<b>x</b>']);
  });
});
