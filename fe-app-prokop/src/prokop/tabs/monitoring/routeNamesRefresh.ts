import type { Prokop } from '../../types';

interface RouteNamesRefresherOptions {
  fetchSections: () => Promise<Prokop.ConfigSection[]>;
  apply: (sections: Prokop.ConfigSection[]) => void;
  onError?: (error: unknown) => void;
  intervalMs: number;
}

function isPageHidden() {
  return typeof document !== 'undefined' && document.hidden === true;
}

// Rule labels and DPI strategy names come from the saved configuration, which
// can change while the page is open (rules edited in another tab, autotune
// applying a strategy). They are read again periodically while the page is
// visible and applied only when they changed (UC-127).
export function createRouteNamesRefresher({
  fetchSections,
  apply,
  onError,
  intervalMs,
}: RouteNamesRefresherOptions) {
  let timer: ReturnType<typeof setInterval> | null = null;
  let generation = 0;
  let lastSignature: string | null = null;

  const refresh = async () => {
    const current = generation;

    try {
      const sections = await fetchSections();
      const signature = JSON.stringify(sections);

      if (current !== generation || signature === lastSignature) {
        return;
      }

      lastSignature = signature;
      apply(sections);
    } catch (error) {
      onError?.(error);

      // The first load still settles the view; later failures keep the
      // last names.
      if (current === generation && lastSignature === null) {
        lastSignature = '';
        apply([]);
      }
    }
  };

  const stop = () => {
    generation += 1;

    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  };

  const start = () => {
    stop();
    lastSignature = null;
    void refresh();

    timer = setInterval(() => {
      if (!isPageHidden()) {
        void refresh();
      }
    }, intervalMs);
  };

  return { start, stop, refresh };
}
