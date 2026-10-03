interface RenderOnAttachDeps {
  isMounted: () => boolean;
  waitForAttach: (root: HTMLElement) => Promise<unknown>;
  renderComponents: () => void;
}

// A LuCI form re-render (CBIMap.save → renderContents) calls render() again
// and swaps in a fresh, empty container without any tab or store change.
// When the page is already mounted, fill the new container once it is in
// the document.
export function renderOnAttach(
  root: HTMLElement,
  deps: RenderOnAttachDeps,
): void {
  if (!deps.isMounted()) {
    return;
  }

  void deps.waitForAttach(root).then(() => {
    if (deps.isMounted()) {
      deps.renderComponents();
    }
  });
}
