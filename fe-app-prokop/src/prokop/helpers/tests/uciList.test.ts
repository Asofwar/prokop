import { describe, expect, it } from 'vitest';
import { uciListValues } from '../uciList';

describe('uciListValues', () => {
  it('reads a list option and a whitespace-separated option alike', () => {
    expect(uciListValues([' a ', '', 'b'])).toEqual(['a', 'b']);
    expect(uciListValues(' a  b\tc ')).toEqual(['a', 'b', 'c']);
    expect(uciListValues(undefined)).toEqual([]);
    expect(uciListValues('')).toEqual([]);
  });
});
