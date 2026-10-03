// Deep links between Prokop pages (admin/services/prokop/<page>). Page
// parameters travel in the URL hash, so a reload or a shared link keeps them.
export type ProkopPage =
  | 'overview'
  | 'monitoring'
  | 'diagnostics'
  | 'autotune'
  | 'history'
  | 'rules'
  | 'settings';

const PROKOP_MENU_PATH = 'admin/services/prokop';

interface LuciUrlBuilder {
  url?: (...parts: string[]) => string;
}

function luci(): LuciUrlBuilder | undefined {
  return (globalThis as unknown as { L?: LuciUrlBuilder }).L;
}

export function prokopPageUrl(
  page: ProkopPage,
  params: Record<string, string> = {},
) {
  const base =
    typeof luci()?.url === 'function'
      ? luci()!.url!(PROKOP_MENU_PATH, page)
      : `/cgi-bin/luci/${PROKOP_MENU_PATH}/${page}`;
  const query = new URLSearchParams(params).toString();

  return query ? `${base}#${query}` : base;
}

export function openProkopPage(
  page: ProkopPage,
  params: Record<string, string> = {},
) {
  window.location.href = prokopPageUrl(page, params);
}

export function readPageParams(hash = window.location.hash) {
  return Object.fromEntries(new URLSearchParams(hash.replace(/^#/, '')));
}
