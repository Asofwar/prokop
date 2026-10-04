import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { socket } from '../socket.service';
import { logger } from '../logger.service';

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static instances: FakeWebSocket[] = [];

  readyState = FakeWebSocket.CONNECTING;
  private listeners = new Map<string, Array<(event: Event) => void>>();

  constructor(_url: string) {
    FakeWebSocket.instances.push(this);
  }

  addEventListener(type: string, listener: (event: Event) => void) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  emit(type: string) {
    for (const listener of this.listeners.get(type) || []) {
      listener(new Event(type));
    }
  }

  close() {}
  send() {}
}

describe('socket service', () => {
  beforeEach(() => {
    socket.resetAll();
    FakeWebSocket.instances = [];
    vi.stubGlobal('WebSocket', FakeWebSocket);
  });

  afterEach(() => {
    socket.resetAll();
    vi.unstubAllGlobals();
  });

  it('keeps the initial subscriber when the first connection fails', () => {
    const onError = vi.fn();

    socket.subscribe('ws://router.test', vi.fn(), onError);
    FakeWebSocket.instances[0].emit('error');

    expect(onError).toHaveBeenCalledOnce();
  });

  // C13: sing-box restarts on every reload and drops the stream; the page
  // opens it again instead of polling through rpcd for good.
  it('reconnects a stream that was open and dropped', () => {
    vi.useFakeTimers();
    try {
      const onMessage = vi.fn();
      const onError = vi.fn();
      socket.subscribe('ws://router.test/traffic', onMessage, onError);
      FakeWebSocket.instances[0].emit('open');
      FakeWebSocket.instances[0].emit('error');
      FakeWebSocket.instances[0].emit('close');
      expect(onError).not.toHaveBeenCalled();
      expect(FakeWebSocket.instances).toHaveLength(1);

      vi.advanceTimersByTime(1000);
      expect(FakeWebSocket.instances).toHaveLength(2);
      FakeWebSocket.instances[1].emit('open');
      expect(onError).not.toHaveBeenCalled();

      // Opened again: the next drop starts from the shortest delay.
      FakeWebSocket.instances[1].emit('close');
      vi.advanceTimersByTime(1000);
      expect(FakeWebSocket.instances).toHaveLength(3);
    } finally {
      vi.useRealTimers();
    }
  });

  it('gives up and reports the drop when the stream does not come back', () => {
    vi.useFakeTimers();
    try {
      const onError = vi.fn();
      socket.subscribe('ws://router.test/traffic', vi.fn(), onError);
      FakeWebSocket.instances[0].emit('open');
      FakeWebSocket.instances[0].emit('close');
      for (const delay of [1000, 2000, 4000, 8000, 15000]) {
        vi.advanceTimersByTime(delay);
        FakeWebSocket.instances[FakeWebSocket.instances.length - 1].emit(
          'close',
        );
      }
      expect(FakeWebSocket.instances).toHaveLength(6);
      expect(onError).toHaveBeenCalledOnce();
      vi.advanceTimersByTime(60000);
      expect(FakeWebSocket.instances).toHaveLength(6);
    } finally {
      vi.useRealTimers();
    }
  });

  it('never reconnects a stream it was asked to disconnect', () => {
    vi.useFakeTimers();
    try {
      socket.subscribe('ws://router.test/traffic', vi.fn(), vi.fn());
      FakeWebSocket.instances[0].emit('open');
      FakeWebSocket.instances[0].emit('close');
      socket.disconnect('ws://router.test/traffic');
      vi.advanceTimersByTime(60000);
      expect(FakeWebSocket.instances).toHaveLength(1);
    } finally {
      vi.useRealTimers();
    }
  });

  // UC-036: the Clash secret travels as the token query parameter of the
  // controller WebSocket URL; it must never reach the console or the logger.
  it('never logs the query string of a socket URL', () => {
    const spies = [
      vi.spyOn(console, 'info').mockImplementation(() => undefined),
      vi.spyOn(console, 'warn').mockImplementation(() => undefined),
      vi.spyOn(console, 'error').mockImplementation(() => undefined),
      vi.spyOn(console, 'log').mockImplementation(() => undefined),
    ];
    logger.clear();

    const url = 'ws://router.test:9090/traffic?token=TOP-SECRET';
    socket.subscribe(url, vi.fn(), vi.fn());
    const ws = FakeWebSocket.instances[0];
    ws.emit('open');
    ws.emit('error');
    ws.emit('close');
    socket.send(url, 'x');

    const printed = spies
      .flatMap((spy) => spy.mock.calls)
      .map((args) => args.join(' '))
      .join('\n');
    expect(printed).toContain('ws://router.test:9090/traffic');
    expect(printed).not.toContain('TOP-SECRET');
    expect(printed).not.toContain('token=');
    expect(logger.getLogs()).not.toContain('TOP-SECRET');

    for (const spy of spies) spy.mockRestore();
  });
});
