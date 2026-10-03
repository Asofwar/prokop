import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { logger } from '../logger.service';

describe('logger service', () => {
  beforeEach(() => {
    vi.spyOn(console, 'info').mockImplementation(() => undefined);
    logger.clear();
  });

  afterEach(() => {
    logger.clear();
    vi.restoreAllMocks();
  });

  // UC-036: a long-open page logs on every poll; the in-memory buffer keeps
  // only the most recent lines.
  it('keeps a bounded buffer of the most recent lines', () => {
    for (let i = 0; i < 5000; i++) {
      logger.info('[TEST]', `line ${i}`);
    }

    const lines = logger.getLogs().split('\n');
    expect(lines.length).toBeLessThanOrEqual(500);
    expect(lines[lines.length - 1]).toBe('[INFO] [TEST] line 4999');
    expect(lines[0]).toBe(`[INFO] [TEST] line ${5000 - lines.length}`);
  });
});
