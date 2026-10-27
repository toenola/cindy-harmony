export function deviceDisplayName(deviceId: string, name: string, unnamed: string,
  devices: Map<string, string>): string {
  const readable = (id: string, value: string): string => {
    const trimmed = value.trim();
    return trimmed.length > 0 && trimmed !== id ? trimmed : '';
  };
  const label = readable(deviceId, name) || readable(deviceId, devices.get(deviceId) ?? '') || unnamed;
  if (label.length === 0) return '';
  const peers = new Set<string>();
  peers.add(deviceId);
  devices.forEach((value: string, id: string): void => {
    if ((readable(id, value) || unnamed).toLowerCase() === label.toLowerCase()) peers.add(id);
  });
  if (peers.size <= 1) return label;
  return label + ' (' + (Array.from(peers).sort().indexOf(deviceId) + 1).toString() + ')';
}
