// A browser tab in the background (FE-7): the page's periodic polls skip
// their turn, so a forgotten tab does not keep the router busy. They resume
// on the first tick after the tab is shown again.
export function isPageHidden(): boolean {
  return typeof document !== 'undefined' && document.hidden === true;
}
