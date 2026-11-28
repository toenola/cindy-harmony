export const SPLIT_HANDLE_PREVIEW_VP = 16;
export const SPLIT_HANDLE_THRESHOLD_VP = 44;
export const SPLIT_HANDLE_KEY_STEP_VP = 16;

export type SplitHandleStep = 'narrow' | 'widen' | 'minimum' | 'maximum';

/** Discrete steps resize but never trigger a full-pane mode. That is a separate explicit action. */
export function splitHandleStep(widthVp: number, minVp: number, maxVp: number, action: SplitHandleStep): number {
  if (!Number.isFinite(widthVp) || !Number.isFinite(minVp) || !Number.isFinite(maxVp) || minVp > maxVp) {
    return widthVp;
  }
  const width = Math.min(maxVp, Math.max(minVp, widthVp));
  if (action === 'minimum') return minVp;
  if (action === 'maximum') return maxVp;
  const delta = action === 'narrow' ? -SPLIT_HANDLE_KEY_STEP_VP : SPLIT_HANDLE_KEY_STEP_VP;
  return Math.min(maxVp, Math.max(minVp, width + delta));
}

export function splitHandlePreviewProgress(overrunVp: number): number {
  if (!Number.isFinite(overrunVp)) return 0;
  return Math.min(1, Math.max(0,
    (Math.abs(overrunVp) - SPLIT_HANDLE_PREVIEW_VP) / (SPLIT_HANDLE_THRESHOLD_VP - SPLIT_HANDLE_PREVIEW_VP)));
}
