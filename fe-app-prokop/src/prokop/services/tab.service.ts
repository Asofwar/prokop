import { getProkopPage, setStandalonePage } from './prokopPage';

type TabInfo = {
  el: HTMLElement;
  id: string;
  active: boolean;
};

type TabChangeCallback = (activeId: string | null, allTabs: TabInfo[]) => void;

export function setProkopPage(pageId: string | null) {
  setStandalonePage(pageId);
  TabService.getInstance().refresh();
}

class TabService {
  private static instance: TabService;
  private observer: MutationObserver | null = null;
  private callback?: TabChangeCallback;
  private lastActiveId: string | null = null;

  private constructor() {
    this.init();
  }

  public static getInstance(): TabService {
    if (!TabService.instance) {
      TabService.instance = new TabService();
    }
    return TabService.instance;
  }

  private init() {
    this.observer = new MutationObserver(() => this.handleMutations());
    this.observer.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['class'],
    });

    // initial check
    this.notify();
  }

  private handleMutations() {
    this.notify();
  }

  private getTabsInfo(): TabInfo[] {
    const tabs = Array.from(
      document.querySelectorAll<HTMLElement>('.cbi-tab, .cbi-tab-disabled'),
    );
    return tabs.map((el) => ({
      el,
      id: el.dataset.tab || '',
      active:
        el.classList.contains('cbi-tab') &&
        !el.classList.contains('cbi-tab-disabled'),
    }));
  }

  private getActiveTabId(): string | null {
    const active = document.querySelector<HTMLElement>(
      '.cbi-tab:not(.cbi-tab-disabled)',
    );
    return active?.dataset.tab || getProkopPage();
  }

  private notify() {
    const tabs = this.getTabsInfo();
    const activeId = this.getActiveTabId();

    if (activeId !== this.lastActiveId) {
      this.lastActiveId = activeId;
      this.callback?.(activeId, tabs);
    }
  }

  public refresh() {
    this.notify();
  }

  // A new subscriber always gets the current tab, even when it was already
  // known before (a page registered before the subscription).
  public onChange(callback: TabChangeCallback) {
    this.callback = callback;
    this.lastActiveId = this.getActiveTabId();
    callback(this.lastActiveId, this.getTabsInfo());
  }
}

export const TabServiceInstance = TabService.getInstance();
