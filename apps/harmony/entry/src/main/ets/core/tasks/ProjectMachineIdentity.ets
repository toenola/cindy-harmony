import { deviceDisplayName } from './DeviceDisplayName';

export class ProjectMachine {
  deviceId: string = '';
  name: string = '';
  online: boolean = false;
}

/** Only visible distinct computers disambiguate a project heading. */
export function projectMachineLabel(deviceId: string, selectedDeviceId: string,
  visibleDevices: ProjectMachine[], offlineLabel: string, unnamed: string = '未命名电脑'): string {
  if (deviceId === selectedDeviceId) return '';
  const device = visibleDevices.find((row: ProjectMachine) => row.deviceId === deviceId);
  const names = new Map<string, string>();
  for (const row of visibleDevices) names.set(row.deviceId, row.name);
  const name = deviceDisplayName(deviceId, device?.name ?? '', unnamed, names);
  return name + (device?.online ? '' : ' · ' + offlineLabel);
}
