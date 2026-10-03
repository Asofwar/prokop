import { Prokop } from '../../../types';

// Clash reports routing roles (not protocols) under these types; protocol
// names such as VLESS or WireGuard stay as technical names.
function getOutboundTypeLabel(type: string) {
  switch (type) {
    case 'Direct':
      return _('Direct');
    case 'Selector':
      return _('Manual selection');
    case 'Reject':
    case 'RejectDrop':
      return _('Block');
    default:
      return type;
  }
}

export function getOutboundFooterLabel(outbound: Prokop.Outbound) {
  return (
    outbound.urlTestInfo?.selectedName ||
    outbound.priorityInfo?.selectedName ||
    outbound.description ||
    getOutboundTypeLabel(outbound.type)
  );
}
