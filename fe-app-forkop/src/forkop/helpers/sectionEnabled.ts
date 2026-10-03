// The enabled flag of a rule as the backend reads it (core/common.uc
// section_enabled, UC-105): unset is on; 1, true, yes or on in any letter
// case is on; any other value is off.
export function isSectionEnabled(value?: string | null) {
  if (value === undefined || value === null) return true;
  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase());
}
