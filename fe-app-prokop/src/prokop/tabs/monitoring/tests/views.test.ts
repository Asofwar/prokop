import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../services/tab.service', () => ({ setProkopPage: vi.fn() }));

import { controllerForView, readMonitoringView } from '../views';

describe('monitoring views', () => {
  it('opens node selection from monitoring#view=nodes', () => {
    expect(readMonitoringView('#view=nodes')).toBe('nodes');
    expect(readMonitoringView('#search=example.com')).toBe('connections');
    expect(readMonitoringView('')).toBe('connections');
  });

  it('runs node selection with the dashboard controller', () => {
    expect(controllerForView('nodes')).toBe('dashboard');
    expect(controllerForView('connections')).toBe('monitoring');
  });
});
