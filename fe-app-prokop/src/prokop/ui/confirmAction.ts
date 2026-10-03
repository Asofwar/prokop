interface ConfirmActionOptions {
  title: string;
  message: string;
  // What will happen, one line per consequence.
  consequences?: string[];
  // Further paragraphs after the consequences.
  notes?: string[];
  confirmLabel: string;
  danger?: boolean;
}

// Replaces window.confirm() for every destructive or disruptive action:
// the dialog names the action and its consequences, and Cancel is the
// default focus so Enter never confirms by accident.
export function confirmAction(options: ConfirmActionOptions): Promise<boolean> {
  return new Promise((resolve) => {
    let settled = false;
    let observer: MutationObserver | undefined;
    const finish = (confirmed: boolean, closeModal = true) => {
      if (settled) return;
      settled = true;
      observer?.disconnect();
      if (closeModal) ui.hideModal();
      resolve(confirmed);
    };

    const cancelButton = E(
      'button',
      { type: 'button', class: 'btn cbi-button', click: () => finish(false) },
      _('Cancel'),
    );
    const confirmButton = E(
      'button',
      {
        type: 'button',
        class: `btn ${options.danger ? 'cbi-button-negative' : 'cbi-button-action'}`,
        click: () => finish(true),
      },
      options.confirmLabel,
    );

    const content = E('div', { class: 'fkp-confirm' }, [
      E('p', {}, options.message),
      ...(options.consequences?.length
        ? [
            E(
              'ul',
              { class: 'fkp-confirm__consequences' },
              options.consequences.map((line) => E('li', {}, line)),
            ),
          ]
        : []),
      ...(options.notes ?? []).map((line) => E('p', {}, line)),
      E('div', { class: 'fkp-confirm__actions' }, [
        cancelButton,
        confirmButton,
      ]),
    ]);

    ui.showModal(options.title, content);
    // A modal closed by LuCI itself (Escape, navigation) counts as cancel.
    if (typeof MutationObserver === 'function') {
      observer = new MutationObserver(() => {
        if (!content.isConnected) finish(false, false);
      });
      observer.observe(document.body, { childList: true, subtree: true });
    }
    cancelButton.focus?.();
  });
}
