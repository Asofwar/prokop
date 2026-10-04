import { logger } from './logger.service';

// eslint-disable-next-line
type Listener = (data: any) => void;
type ErrorListener = (error: Event | string) => void;

// Socket URLs of the Clash controller carry the secret as the token query
// parameter (UC-036): logs show the URL without its query string.
function loggableUrl(url: string): string {
  return url.split('?')[0];
}

// A stream that was open and dropped (sing-box restarts on every reload) is
// opened again after 1, 2, 4, 8 and 15 s (C13). Only when that fails, or
// when the first connection fails, do the subscribers hear of it and fall
// back to polling through rpcd.
const RECONNECT_DELAYS_MS = [1000, 2000, 4000, 8000, 15000];

class SocketManager {
  private static instance: SocketManager;
  private sockets = new Map<string, WebSocket>();
  // URLs whose stream has been open since they were subscribed, and the
  // reconnect in progress for one that dropped.
  private opened = new Set<string>();
  private reconnects = new Map<
    string,
    { attempt: number; timer: ReturnType<typeof setTimeout> | null }
  >();
  private listeners = new Map<string, Set<Listener>>();
  private connected = new Map<string, boolean>();
  private errorListeners = new Map<string, Set<ErrorListener>>();

  private constructor() {}

  static getInstance(): SocketManager {
    if (!SocketManager.instance) {
      SocketManager.instance = new SocketManager();
    }
    return SocketManager.instance;
  }

  resetAll(): void {
    for (const [url, ws] of this.sockets.entries()) {
      try {
        if (
          ws.readyState === WebSocket.OPEN ||
          ws.readyState === WebSocket.CONNECTING
        ) {
          ws.close();
        }
      } catch (err) {
        logger.error(
          '[SOCKET]',
          `resetAll: failed to close socket ${loggableUrl(url)}`,
          err,
        );
      }
    }

    this.sockets.clear();
    this.clearReconnects();
    this.listeners.clear();
    this.errorListeners.clear();
    this.connected.clear();
    logger.info('[SOCKET]', 'All connections and state have been reset.');
  }

  connect(url: string): void {
    if (this.sockets.has(url)) return;

    let ws: WebSocket;

    try {
      ws = new WebSocket(url);
    } catch (err) {
      logger.error(
        '[SOCKET]',
        `failed to construct WebSocket for ${loggableUrl(url)}:`,
        err,
      );
      this.triggerError(url, err instanceof Event ? err : String(err));
      return;
    }

    this.sockets.set(url, ws);
    this.connected.set(url, false);
    if (!this.listeners.has(url)) this.listeners.set(url, new Set());
    if (!this.errorListeners.has(url)) this.errorListeners.set(url, new Set());

    ws.addEventListener('open', () => {
      if (this.sockets.get(url) !== ws) return;
      this.connected.set(url, true);
      this.opened.add(url);
      this.reconnects.delete(url);
      logger.info('[SOCKET]', 'Connected to', loggableUrl(url));
    });

    ws.addEventListener('message', (event) => {
      const handlers = this.listeners.get(url);
      if (handlers) {
        for (const handler of handlers) {
          try {
            handler(event.data);
          } catch (err) {
            logger.error(
              '[SOCKET]',
              `Handler error for ${loggableUrl(url)}:`,
              err,
            );
          }
        }
      }
    });

    ws.addEventListener('close', () => {
      // A socket replaced by a reconnect, or one disconnect() closed.
      if (this.sockets.get(url) !== ws) return;
      this.connected.set(url, false);
      // Gone from the map: a later subscribe() or reconnect opens it again.
      this.sockets.delete(url);
      logger.warn('[SOCKET]', `Disconnected: ${loggableUrl(url)}`);
      if (this.scheduleReconnect(url)) return;
      this.triggerError(url, 'Connection closed');
    });

    ws.addEventListener('error', (err) => {
      if (this.sockets.get(url) !== ws) return;
      logger.error('[SOCKET]', `Socket error for ${loggableUrl(url)}:`, err);
      // An error on a stream that was open is followed by its close, which
      // reconnects.
      if (this.opened.has(url)) return;
      this.triggerError(url, err);
    });
  }

  private scheduleReconnect(url: string): boolean {
    if (!this.opened.has(url) || !this.listeners.get(url)?.size) return false;
    const state = this.reconnects.get(url) || { attempt: 0, timer: null };
    if (state.attempt >= RECONNECT_DELAYS_MS.length) {
      this.reconnects.delete(url);
      this.opened.delete(url);
      return false;
    }
    const delay = RECONNECT_DELAYS_MS[state.attempt];
    state.attempt += 1;
    state.timer = setTimeout(() => {
      state.timer = null;
      if (this.reconnects.get(url) !== state || this.sockets.has(url)) return;
      this.connect(url);
    }, delay);
    this.reconnects.set(url, state);
    logger.info(
      '[SOCKET]',
      `Reconnecting to ${loggableUrl(url)} in ${delay} ms (attempt ${state.attempt})`,
    );
    return true;
  }

  private clearReconnect(url: string) {
    const state = this.reconnects.get(url);
    if (state?.timer) clearTimeout(state.timer);
    this.reconnects.delete(url);
    this.opened.delete(url);
  }

  private clearReconnects() {
    for (const url of [...this.reconnects.keys()]) this.clearReconnect(url);
    this.opened.clear();
  }

  subscribe(url: string, listener: Listener, onError?: ErrorListener): void {
    if (!this.errorListeners.has(url)) {
      this.errorListeners.set(url, new Set());
    }
    if (onError) {
      this.errorListeners.get(url)?.add(onError);
    }

    if (!this.sockets.has(url)) {
      this.connect(url);
    }

    if (!this.listeners.has(url)) {
      this.listeners.set(url, new Set());
    }
    this.listeners.get(url)?.add(listener);
  }

  unsubscribe(url: string, listener: Listener, onError?: ErrorListener): void {
    this.listeners.get(url)?.delete(listener);
    if (onError) {
      this.errorListeners.get(url)?.delete(onError);
    }
  }

  // eslint-disable-next-line
  send(url: string, data: any): void {
    const ws = this.sockets.get(url);
    if (ws && this.connected.get(url)) {
      ws.send(typeof data === 'string' ? data : JSON.stringify(data));
    } else {
      logger.warn(
        '[SOCKET]',
        `Cannot send: not connected to ${loggableUrl(url)}`,
      );
      this.triggerError(url, 'Not connected');
    }
  }

  disconnect(url: string): void {
    const ws = this.sockets.get(url);
    this.clearReconnect(url);
    this.sockets.delete(url);
    this.listeners.delete(url);
    this.errorListeners.delete(url);
    this.connected.delete(url);
    ws?.close();
  }

  disconnectAll(): void {
    for (const url of new Set([
      ...this.sockets.keys(),
      ...this.reconnects.keys(),
    ])) {
      this.disconnect(url);
    }
  }

  private triggerError(url: string, err: Event | string): void {
    const handlers = this.errorListeners.get(url);
    if (handlers) {
      for (const cb of handlers) {
        try {
          cb(err);
        } catch (e) {
          logger.error(
            '[SOCKET]',
            `Error handler threw for ${loggableUrl(url)}:`,
            e,
          );
        }
      }
    }
  }
}

export const socket = SocketManager.getInstance();
