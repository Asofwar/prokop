type HtmlTag = keyof HTMLElementTagNameMap;

type HtmlElement<T extends HtmlTag> = HTMLElementTagNameMap[T];

type HtmlAttributes<T extends HtmlTag = 'div'> = Partial<
  Omit<HtmlElement<T>, 'style' | 'children' | 'click'> & {
    style?: string | Partial<CSSStyleDeclaration>;
    class?: string;
    'aria-busy'?: string;
    'aria-disabled'?: string;
    'aria-label'?: string;
    'aria-pressed'?: string;
    for?: string;
    'data-latency-section'?: string;
    'data-view'?: string;
    click?: (event: MouseEvent) => void;
    keydown?: (event: KeyboardEvent) => void;
    onclick?: (event: MouseEvent) => void;
  }
>;

declare global {
  const fs: {
    read(path: string): Promise<string>;
    write(path: string, data: string): Promise<void>;
    remove(path: string): Promise<void>;
    exec(
      command: string,
      args?: string[],
      env?: Record<string, string>,
    ): Promise<{
      stdout: string;
      stderr: string;
      code?: number;
    }>;
  };

  const E: <T extends HtmlTag>(
    type: T,
    attr?: HtmlAttributes<T> | null,
    children?: (Node | string)[] | Node | string,
  ) => HTMLElementTagNameMap[T];

  const uci: {
    load: (packages: string | string[]) => Promise<string>;
    unload?: (packages: string | string[]) => void;
    // Saved but not applied changes of this session, by package.
    changes?: () => Promise<Record<string, unknown>>;
    sections: (conf: string, type?: string, cb?: () => void) => Promise<T>;
  };

  const _ = (_key: string) => string;

  const ui = {
    // LuCI renders a string title as HTML: pass non-literal titles through asText().
    showModal: (
      _title: string | (Node | string)[],
      _content: HTMLElement | (Node | string)[],
    ) => undefined,
    hideModal: () => undefined,
    addNotification: (
      _title: string | (Node | string)[],
      _children: HtmlElement | HtmlElement[],
      ..._classNames: string[]
    ) => HTMLElement,
  };
}

export {};
