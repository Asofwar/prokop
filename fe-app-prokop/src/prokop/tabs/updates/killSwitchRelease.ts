// The newest release without the VPN kill-switch. Installing it or an older
// one removes the kill-switch protection first (service/package.uc).
const LAST_RELEASE_WITHOUT_KILL_SWITCH = [1, 0, 31];

export function releaseLacksKillSwitch(version: string): boolean {
  const parts = /^(\d+)\.(\d+)\.(\d+)/.exec(`${version}`);
  if (!parts) {
    return false;
  }
  for (let i = 0; i < 3; i++) {
    const value = Number(parts[i + 1]);
    if (value !== LAST_RELEASE_WITHOUT_KILL_SWITCH[i]) {
      return value < LAST_RELEASE_WITHOUT_KILL_SWITCH[i];
    }
  }
  return true;
}
