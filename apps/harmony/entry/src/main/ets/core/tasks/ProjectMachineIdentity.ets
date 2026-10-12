export class ProjectMachine {
  deviceId: string = '';
  name: string = '';
  online: boolean = false;
}

/** Only visible distinct computers disambiguate a project heading. */
export function projectMachineLabel(deviceId: string, selectedDeviceId: string,
  visibleDevices: ProjectMachine[], offlineLabel: string): string {
  if (deviceId === selectedDeviceId) return '';
  const device = visibleDevices.find((row: ProjectMachine) => row.deviceId === deviceId);
  const name = device?.name.trim() || deviceId;
  const duplicate = visibleDevices.some((row: ProjectMachine) => row.deviceId !== deviceId
    && row.name.trim().toLowerCase() === name.toLowerCase());
  return `${name}${duplicate ? ' · ' + deviceId : ''}${device?.online ? '' : ' · ' + offlineLabel}`;
}
