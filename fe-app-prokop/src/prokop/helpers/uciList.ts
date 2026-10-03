// The values of a UCI list option as get_readonly_config_sections returns
// it: a list, or a single option holding whitespace-separated values.
export function uciListValues(value?: string[] | string | null): string[] {
  if (!value) {
    return [];
  }

  const items = Array.isArray(value) ? value : String(value).split(/\s+/);
  return items
    .map((item) => (item == null ? '' : String(item).trim()))
    .filter(Boolean);
}
