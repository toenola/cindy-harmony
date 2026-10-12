export class UsageLimitWait {
  resumeAt: number = 0;
}

export class UsageLimitWaitState {
  resumeAt: number = 0;
  visible: boolean = false;
  cancelSupported: boolean = false;
  canCancel: boolean = false;
  cancelling: boolean = false;
  cancelError: string = '';
}

export function readUsageLimitWait(value: Object | undefined): UsageLimitWait | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const resumeAt = (value as Record<string, Object>)['resumeAt'];
  if (typeof resumeAt !== 'number' || !Number.isFinite(resumeAt) || resumeAt <= 0) {
    return undefined;
  }
  const wait = new UsageLimitWait();
  wait.resumeAt = resumeAt;
  return wait;
}

export function shouldShowUsageLimitWait(error: string, wait: UsageLimitWait | undefined): boolean {
  return error.length > 0 && wait !== undefined;
}

export function usageLimitWaitCancelUnsupported(message: string): boolean {
  return /^\[?(CHANNEL_NOT_ALLOWED|UNSUPPORTED_CAPABILITY|UNSUPPORTED|NOT_SUPPORTED|METHOD_NOT_FOUND)(\]|\s|$)/i
    .test(message)
    || /(?:not registered|No handler).*maker:input:cancel-usage-limit-wait/i.test(message);
}
