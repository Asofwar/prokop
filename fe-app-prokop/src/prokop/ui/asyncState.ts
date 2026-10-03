// One lifecycle for every asynchronous block: a request can finish, fail,
// time out or become irrelevant, and the block must never stay in
// "loading" forever or show an answer to an older request.

export type AsyncPhase =
  | 'idle'
  | 'loading'
  | 'ready'
  | 'empty'
  | 'error'
  | 'timeout';

export interface AsyncSnapshot<T> {
  phase: AsyncPhase;
  // Last good data; kept while refreshing and after a failed refresh.
  data?: T;
  error?: string;
  // Milliseconds timestamp of the last successful load.
  updatedAt?: number;
}

export interface AsyncLoaderOptions<T> {
  load: () => Promise<T>;
  timeoutMs?: number;
  isEmpty?: (data: T) => boolean;
  onChange?: (snapshot: AsyncSnapshot<T>) => void;
  now?: () => number;
}

export class AsyncTimeoutError extends Error {
  constructor(public readonly timeoutMs: number) {
    super(`Timed out after ${timeoutMs} ms`);
  }
}

function errorMessage(error: unknown) {
  if (error instanceof Error) return error.message;
  return typeof error === 'string' ? error : '';
}

function withDeadline<T>(promise: Promise<T>, timeoutMs?: number) {
  if (!timeoutMs) return promise;

  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(
      () => reject(new AsyncTimeoutError(timeoutMs)),
      timeoutMs,
    );
  });

  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

export function createAsyncLoader<T>(options: AsyncLoaderOptions<T>) {
  const now = options.now ?? Date.now;
  let generation = 0;
  let snapshot: AsyncSnapshot<T> = { phase: 'idle' };

  const set = (next: AsyncSnapshot<T>) => {
    snapshot = next;
    options.onChange?.(snapshot);
  };

  async function run(): Promise<AsyncSnapshot<T>> {
    const current = ++generation;
    set({ ...snapshot, phase: 'loading', error: undefined });

    try {
      const data = await withDeadline(
        Promise.resolve().then(options.load),
        options.timeoutMs,
      );
      if (current !== generation) return snapshot;

      set({
        phase: options.isEmpty?.(data) ? 'empty' : 'ready',
        data,
        updatedAt: now(),
      });
    } catch (error) {
      if (current !== generation) return snapshot;

      set({
        ...snapshot,
        phase: error instanceof AsyncTimeoutError ? 'timeout' : 'error',
        error: errorMessage(error),
      });
    }

    return snapshot;
  }

  // Answers to requests started before this call are dropped.
  function invalidate() {
    generation += 1;
    if (snapshot.phase === 'loading') {
      set({
        ...snapshot,
        phase: snapshot.data === undefined ? 'idle' : 'ready',
      });
    }
  }

  return {
    run,
    invalidate,
    get: () => snapshot,
  };
}

export function isStale(
  snapshot: AsyncSnapshot<unknown>,
  maxAgeMs: number,
  now = Date.now(),
) {
  return (
    snapshot.updatedAt !== undefined && now - snapshot.updatedAt > maxAgeMs
  );
}
