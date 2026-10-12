export type InputDeliveryState = 'pending' | 'accepted' | 'removed' | 'unknown';

export class InputDeliveryReceipt {
  clientId: string = '';
  state: InputDeliveryState = 'unknown';
}

export class InputDeliveryProjection {
  inputDeliveryVersion: number | undefined = undefined;
  deliveryReceipts: InputDeliveryReceipt[] = [];
}

export function boundedDeliveryClientIds(clientIds: string[]): string[] {
  const result: string[] = [];
  const seen = new Set<string>();
  for (const clientId of clientIds) {
    if (typeof clientId !== 'string' || clientId.length === 0 || clientId.length > 256 || seen.has(clientId)) continue;
    seen.add(clientId);
    result.push(clientId);
    if (result.length === 64) break;
  }
  return result;
}

export function inputDeliveryStateRank(state: InputDeliveryState): number {
  if (state === 'removed') return 3;
  if (state === 'accepted') return 2;
  if (state === 'pending') return 1;
  return 0;
}

export function parseInputDeliveryProjection(value: Object | undefined): InputDeliveryProjection {
  const projection = new InputDeliveryProjection();
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return projection;
  }
  const raw = value as Record<string, Object>;
  if (raw['inputDeliveryVersion'] !== 1) return projection;
  projection.inputDeliveryVersion = 1;
  const receipts = raw['deliveryReceipts'];
  if (!Array.isArray(receipts)) return projection;
  const rows = receipts as Object[];
  for (const row of rows.slice(0, 64)) {
    if (row === undefined || row === null || typeof row !== 'object' || Array.isArray(row)) continue;
    const record = row as Record<string, Object>;
    const clientId = record['clientId'];
    const state = record['state'];
    if (typeof clientId !== 'string' || clientId.length === 0 || clientId.length > 256) continue;
    if (state !== 'pending' && state !== 'accepted' && state !== 'removed' && state !== 'unknown') continue;
    const receipt = new InputDeliveryReceipt();
    receipt.clientId = clientId;
    receipt.state = state as InputDeliveryState;
    const previous = projection.deliveryReceipts.find((entry: InputDeliveryReceipt) => entry.clientId === clientId);
    if (previous === undefined) projection.deliveryReceipts.push(receipt);
    else if (inputDeliveryStateRank(receipt.state) > inputDeliveryStateRank(previous.state)) previous.state = receipt.state;
  }
  return projection;
}

export function inputDeliveryResendAllowed(state: InputDeliveryState, locallyProvenUnsent: boolean): boolean {
  return state === 'unknown' && locallyProvenUnsent;
}
