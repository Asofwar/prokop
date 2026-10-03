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

  return new Date(timestampSeconds * 1000).toLocaleString();
}
