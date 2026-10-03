// "5 min ago" style times for status summaries; older times show the date.
export function formatRelativeTime(
  timestampSeconds: number,
  nowMs = Date.now(),
) {
  const seconds = Math.max(0, Math.round(nowMs / 1000 - timestampSeconds));

  if (seconds < 60) return _('just now');
  if (seconds < 3600) {
    return _('%d min ago').replace('%d', String(Math.floor(seconds / 60)));
  }
  if (seconds < 86400) {
    return _('%d h ago').replace('%d', String(Math.floor(seconds / 3600)));
  }

  return formatDateTime(timestampSeconds);
}

// Dates follow the LuCI UI language (<html lang>), not the browser locale.
// LuCI language codes may use '_' (zh_Hans); an unknown code falls back to
// the browser default instead of throwing.
export function uiLocale(): string | undefined {
  const lang =
    typeof document === 'undefined'
      ? ''
      : (document.documentElement?.lang || '').replace(/_/g, '-');
  if (!lang) return undefined;
  try {
    return Intl.DateTimeFormat.supportedLocalesOf([lang])[0];
  } catch (_error) {
    return undefined;
  }
}

export function formatDateTime(timestampSeconds: number) {
  return new Date(timestampSeconds * 1000).toLocaleString(uiLocale());
}

export function formatDate(timestampSeconds: number) {
  return new Date(timestampSeconds * 1000).toLocaleDateString(uiLocale(), {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
}
