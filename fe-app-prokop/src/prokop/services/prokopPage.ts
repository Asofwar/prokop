// Each Prokop page is its own LuCI view. A page hosting one controller
// (dashboard, diagnostic, monitoring) registers its id and counts as the
// active tab; the settings page keeps real form tabs.
let standalonePage: string | null = null;

export function setStandalonePage(pageId: string | null) {
  standalonePage = pageId || null;
}

export function getProkopPage() {
  return standalonePage;
}
