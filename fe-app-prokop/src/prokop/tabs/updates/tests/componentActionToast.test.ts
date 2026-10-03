import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { componentActionSuccessText } from '../componentActionToast';

const g = globalThis as unknown as { _: (key: string) => string };
const ru: Record<string, string> = {
  '%s has been installed': '%s установлен',
  '%s has been removed': '%s удалён',
  '%s has been enabled': '%s включён',
  'Direct Proxy': 'Прямой прокси',
};

describe('componentActionSuccessText', () => {
  const original = g._;

  beforeEach(() => {
    g._ = (key: string) => ru[key] ?? key;
  });

  afterEach(() => {
    g._ = original;
  });

  it('builds a localized toast from the component and action', () => {
    expect(
      componentActionSuccessText({ component: 'sing_box', action: 'install' }),
    ).toBe('sing-box установлен');
    expect(
      componentActionSuccessText({
        component: 'sing_box',
        action: 'install_extended',
      }),
    ).toBe('sing-box установлен');
    expect(
      componentActionSuccessText({ component: 'zapret', action: 'remove' }),
    ).toBe('Zapret удалён');
    expect(
      componentActionSuccessText({
        component: 'direct_proxy',
        action: 'enable',
      }),
    ).toBe('Прямой прокси включён');
  });

  it('never shows the backend prose', () => {
    const text = componentActionSuccessText({
      component: 'byedpi',
      action: 'install',
      message: 'ByeDPI package has been installed',
    } as never);

    expect(text).not.toContain('package');
  });

  it('names the Packet Steering mode', () => {
    expect(
      componentActionSuccessText({
        component: 'packet_steering',
        action: 'restore',
      }),
    ).toBe('Packet Steering normal mode has been restored');
  });

  it('reports a recovered self-update as a rollback', () => {
    expect(
      componentActionSuccessText({
        component: 'prokop',
        action: 'install',
        status: 'recovered',
      }),
    ).toContain('rolled back');
  });
});
