import { Prokop } from '../../../types';

export function getOutboundFooterLabel(outbound: Prokop.Outbound) {
  return (
    outbound.urlTestInfo?.selectedName ||
    outbound.priorityInfo?.selectedName ||
    outbound.description ||
    outbound.type
  );
}
