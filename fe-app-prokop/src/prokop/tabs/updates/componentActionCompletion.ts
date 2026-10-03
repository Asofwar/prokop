import type { Prokop } from '../../types';

export function shouldApplyCompletedComponentActionResult(
  result: Pick<Prokop.ComponentActionResult, 'action'>,
  notify: boolean,
) {
  return result.action !== 'check_update' || notify;
}
