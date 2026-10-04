import { asText } from '../../helpers/asText';
import { renderButton } from '../button/renderButton';
import { copyToClipboard } from '../../helpers/copyToClipboard';
import { downloadAsTxt } from '../../helpers/downloadAsTxt';

interface ModalTextContext {
  maskValues: boolean;
}

interface RenderModalOptions {
  getText?: (context: ModalTextContext) => string | Promise<string>;
  maskText?: (text: string) => string;
  refreshMs?: number;
  initialAutoRefresh?: boolean;
  showAutoRefreshToggle?: boolean;
  showMaskValuesToggle?: boolean;
  initialMaskValues?: boolean;
  startAtEnd?: boolean;
  autoRefreshLabel?: string;
  maskValuesLabel?: string;
}

export function renderModal(
  text: string,
  name: string,
  options?: RenderModalOptions,
) {
  let rawText = text ?? '';
  let currentText = '';
  let refreshInFlight = false;
  let pendingRefresh = false;
  let pendingForcedRefresh = false;
  let refreshSessionId = 0;
  let timer: ReturnType<typeof setInterval> | undefined;
  let observer: MutationObserver | undefined;
  let autoRefreshEnabled =
    options?.initialAutoRefresh ?? Boolean(options?.getText);
  let maskValuesEnabled = options?.initialMaskValues ?? true;
  let shouldScrollToBottomOnMount = Boolean(options?.startAtEnd);
  let autoRefreshInput: HTMLInputElement | undefined;
  let maskValuesInput: HTMLInputElement | undefined;

  const getDisplayText = (value: string) => {
    if (maskValuesEnabled && options?.maskText) {
      return options.maskText(value);
    }

    return value;
  };

  const codeEl = E('code', {}, '') as HTMLElement;
  const contentEl = E(
    'pre',
    { class: 'fkp-partial-modal__content' },
    codeEl,
  ) as HTMLElement;

  const stopRefreshTimer = () => {
    if (timer) {
      clearInterval(timer);
      timer = undefined;
    }
  };

  const isPageHidden = () =>
    typeof document !== 'undefined' && document.hidden === true;

  // A hidden tab skips the timed refreshes and catches up when it is shown
  // again (UC-126).
  const handleVisibilityChange = () => {
    if (!body.isConnected) {
      destroyLiveRefresh();
      return;
    }

    requestRefresh();
  };

  const destroyLiveRefresh = () => {
    refreshSessionId += 1;
    pendingRefresh = false;
    pendingForcedRefresh = false;
    stopRefreshTimer();

    observer?.disconnect();
    observer = undefined;

    if (typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    }
  };

  const scrollToBottom = () => {
    contentEl.scrollTop = contentEl.scrollHeight;
  };

  const scheduleInitialScrollToBottom = () => {
    if (!shouldScrollToBottomOnMount || !body.isConnected) {
      return;
    }

    shouldScrollToBottomOnMount = false;

    requestAnimationFrame(() => {
      scrollToBottom();
    });
  };

  const updateText = (nextText: string) => {
    const normalizedText = nextText ?? '';

    const shouldStickToBottom =
      shouldScrollToBottomOnMount ||
      contentEl.scrollTop + contentEl.clientHeight >=
        contentEl.scrollHeight - 16;

    if (normalizedText === currentText) {
      if (shouldStickToBottom) {
        requestAnimationFrame(() => {
          scrollToBottom();
        });
      }

      return;
    }

    currentText = normalizedText;
    codeEl.textContent = currentText;

    if (shouldStickToBottom) {
      requestAnimationFrame(() => {
        scrollToBottom();
      });
    }
  };

  const updateDisplayedTextFromRaw = () => {
    updateText(getDisplayText(rawText));
  };

  const refreshText = async (force = false) => {
    if (
      !options?.getText ||
      (!force && !autoRefreshEnabled) ||
      refreshInFlight
    ) {
      return;
    }

    if (!body.isConnected) {
      return;
    }

    refreshInFlight = true;
    const sessionId = refreshSessionId;

    try {
      const nextText = await options.getText({
        maskValues: options.maskText ? false : maskValuesEnabled,
      });

      if (!body.isConnected || (!force && !autoRefreshEnabled)) {
        return;
      }

      if (sessionId !== refreshSessionId) {
        return;
      }

      const normalizedText = nextText ?? '';
      rawText = normalizedText;
      updateText(getDisplayText(normalizedText));
    } catch (error) {
      console.warn('[renderModal] failed to refresh modal content', error);
    } finally {
      refreshInFlight = false;

      if (pendingRefresh) {
        const shouldForceRefresh = pendingForcedRefresh;
        pendingRefresh = false;
        pendingForcedRefresh = false;

        if ((shouldForceRefresh || autoRefreshEnabled) && body.isConnected) {
          void refreshText(shouldForceRefresh);
        }
      }
    }
  };

  // Timed refreshes run at most once per refreshMs: a tick that finds the
  // previous request still running is skipped rather than queued (UC-126).
  const requestRefresh = () => {
    if (
      !options?.getText ||
      !autoRefreshEnabled ||
      refreshInFlight ||
      isPageHidden()
    ) {
      return;
    }

    void refreshText();
  };

  const requestForcedRefresh = () => {
    if (!options?.getText) {
      return;
    }

    if (refreshInFlight) {
      pendingRefresh = true;
      pendingForcedRefresh = true;
      return;
    }

    void refreshText(true);
  };

  const startRefreshTimer = () => {
    if (
      !options?.getText ||
      !autoRefreshEnabled ||
      timer ||
      typeof document === 'undefined'
    ) {
      return;
    }

    timer = setInterval(() => {
      requestRefresh();
    }, options.refreshMs ?? 3000);
  };

  const setAutoRefreshEnabled = (nextValue: boolean) => {
    autoRefreshEnabled = nextValue;
    refreshSessionId += 1;
    pendingRefresh = false;
    pendingForcedRefresh = false;

    if (autoRefreshInput) {
      autoRefreshInput.checked = nextValue;
    }

    if (nextValue) {
      startRefreshTimer();
      requestRefresh();
      return;
    }

    stopRefreshTimer();
  };

  const setMaskValuesEnabled = (nextValue: boolean) => {
    maskValuesEnabled = nextValue;
    refreshSessionId += 1;
    pendingRefresh = false;
    pendingForcedRefresh = false;

    if (maskValuesInput) {
      maskValuesInput.checked = nextValue;
    }

    if (options?.maskText) {
      updateDisplayedTextFromRaw();
      return;
    }

    requestForcedRefresh();
  };

  const footerChildren: HTMLElement[] = [
    renderButton({
      classNames: ['cbi-button-apply'],
      text: _('Download'),
      onClick: () => downloadAsTxt(currentText, name),
    }),
    renderButton({
      classNames: ['cbi-button-apply'],
      text: _('Copy'),
      onClick: () => copyToClipboard(`\`\`\`${name}\n${currentText}\n\`\`\``),
    }),
    renderButton({
      classNames: ['cbi-button-remove'],
      text: _('Close'),
      onClick: () => {
        destroyLiveRefresh();
        ui.hideModal();
      },
    }),
  ];

  if (options?.getText && options?.showAutoRefreshToggle) {
    autoRefreshInput = document.createElement('input');
    autoRefreshInput.type = 'checkbox';
    autoRefreshInput.className = 'cbi-input-checkbox';
    autoRefreshInput.checked = autoRefreshEnabled;
    autoRefreshInput.addEventListener('change', () => {
      setAutoRefreshEnabled(autoRefreshInput!.checked);
    });

    footerChildren.unshift(
      E('label', { class: 'fkp-partial-modal__checkbox' }, [
        autoRefreshInput,
        E(
          'span',
          { class: 'fkp-partial-modal__checkbox-text' },
          asText(options.autoRefreshLabel ?? _('Auto refresh')),
        ),
      ]) as HTMLElement,
    );
  }

  if (
    (options?.getText || options?.maskText) &&
    options?.showMaskValuesToggle
  ) {
    maskValuesInput = document.createElement('input');
    maskValuesInput.type = 'checkbox';
    maskValuesInput.className = 'cbi-input-checkbox';
    maskValuesInput.checked = maskValuesEnabled;
    maskValuesInput.addEventListener('change', () => {
      setMaskValuesEnabled(maskValuesInput!.checked);
    });

    footerChildren.unshift(
      E('label', { class: 'fkp-partial-modal__checkbox' }, [
        maskValuesInput,
        E(
          'span',
          { class: 'fkp-partial-modal__checkbox-text' },
          asText(options.maskValuesLabel ?? _('Hide values')),
        ),
      ]) as HTMLElement,
    );
  }

  const body = E('div', { class: 'fkp-partial-modal__body' }, [
    E('div', {}, [
      contentEl,

      E('div', { class: 'fkp-partial-modal__footer' }, footerChildren),
    ]),
  ]) as HTMLElement;

  if (
    (options?.getText || options?.startAtEnd) &&
    typeof document !== 'undefined'
  ) {
    observer = new MutationObserver(() => {
      if (!body.isConnected) {
        destroyLiveRefresh();
        return;
      }

      scheduleInitialScrollToBottom();
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true,
    });

    scheduleInitialScrollToBottom();
  }

  if (options?.getText && typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', handleVisibilityChange);
    startRefreshTimer();
    requestRefresh();
  }

  updateDisplayedTextFromRaw();

  return body;
}
