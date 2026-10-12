import { DlError } from './DlProtocol';

export function isRemoteBusyError(error: Object | undefined): boolean {
  if (error instanceof DlError && error.code === 'BACKPRESSURE') return true;
  return isRemoteBusyMessage(error instanceof Error ? error.message : typeof error === 'string' ? error : '');
}

export function isRemoteBusyMessage(message: string): boolean {
  return /BACKPRESSURE|local remote invoke queue is full|remote invoke expired before dispatch/i.test(message);
}
