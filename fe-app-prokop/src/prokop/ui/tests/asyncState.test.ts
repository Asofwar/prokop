import { afterEach, describe, expect, it, vi } from 'vitest';

import { createAsyncLoader, isStale, type AsyncSnapshot } from '../asyncState';

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

afterEach(() => {
  vi.useRealTimers();
});

describe('createAsyncLoader', () => {
  it('goes idle → loading → ready and stamps the load time', async () => {
    const phases: string[] = [];
    const loader = createAsyncLoader({
      load: async () => ['a'],
      onChange: (snapshot) => phases.push(snapshot.phase),
      now: () => 1000,
    });

    expect(loader.get().phase).toBe('idle');
    const result = await loader.run();

    expect(phases).toEqual(['loading', 'ready']);
    expect(result).toEqual({ phase: 'ready', data: ['a'], updatedAt: 1000 });
  });

  it('reports empty data as empty', async () => {
    const loader = createAsyncLoader({
      load: async () => [] as string[],
      isEmpty: (data) => data.length === 0,
    });

    expect((await loader.run()).phase).toBe('empty');
  });

  it('turns a thrown error into an error state instead of staying loading', async () => {
    const loader = createAsyncLoader({
      load: async () => {
        throw new Error('rpc failed');
      },
    });

    expect(await loader.run()).toMatchObject({
      phase: 'error',
      error: 'rpc failed',
    });
  });

  it('turns a synchronous throw into an error state', async () => {
    const loader = createAsyncLoader<string>({
      load: () => {
        throw new Error('sync');
      },
    });

    expect((await loader.run()).phase).toBe('error');
  });

  it('times out a request that never answers', async () => {
    vi.useFakeTimers();
    const loader = createAsyncLoader({
      load: () => new Promise<string>(() => undefined),
      timeoutMs: 15000,
    });

    const pending = loader.run();
    await vi.advanceTimersByTimeAsync(15000);

    expect((await pending).phase).toBe('timeout');
  });

  it('keeps the last good data when a refresh fails', async () => {
    let fail = false;
    const loader = createAsyncLoader({
      load: async () => {
        if (fail) throw new Error('offline');
        return 'good';
      },
    });

    await loader.run();
    fail = true;
    const snapshot = await loader.run();

    expect(snapshot).toMatchObject({ phase: 'error', data: 'good' });
  });

  it('drops the answer of an older request that finishes last', async () => {
    const first = deferred<string>();
    const second = deferred<string>();
    const answers = [first.promise, second.promise];
    const seen: AsyncSnapshot<string>[] = [];
    const loader = createAsyncLoader({
      load: () => answers.shift()!,
      onChange: (snapshot) => seen.push(snapshot),
    });

    const older = loader.run();
    const newer = loader.run();
    second.resolve('new');
    await newer;
    first.resolve('old');
    await older;

    expect(loader.get().data).toBe('new');
    expect(seen.some((snapshot) => snapshot.data === 'old')).toBe(false);
  });

  it('drops in-flight answers after invalidate()', async () => {
    const answer = deferred<string>();
    const loader = createAsyncLoader({ load: () => answer.promise });

    const pending = loader.run();
    loader.invalidate();
    answer.resolve('late');
    await pending;

    expect(loader.get()).toEqual({ phase: 'idle', error: undefined });
  });
});

describe('isStale', () => {
  it('marks data older than the allowed age as stale', () => {
    expect(isStale({ phase: 'ready', updatedAt: 0 }, 30000, 30001)).toBe(true);
    expect(isStale({ phase: 'ready', updatedAt: 0 }, 30000, 30000)).toBe(false);
    expect(isStale({ phase: 'idle' }, 30000, 99999)).toBe(false);
  });
});
