export function createPriorityMembersState() {
  const expanded = new Set<string>();
  const key = (sectionName: string, outboundCode: string) =>
    JSON.stringify([sectionName, outboundCode]);

  return {
    isExpanded(sectionName: string, outboundCode: string) {
      return expanded.has(key(sectionName, outboundCode));
    },
    setExpanded(sectionName: string, outboundCode: string, open: boolean) {
      const stateKey = key(sectionName, outboundCode);
      if (open) {
        expanded.add(stateKey);
      } else {
        expanded.delete(stateKey);
      }
    },
  };
}
