/** Phase 1: sale/purchase immutability + Phase 2 gating for other voucher types. */
export const PHASE2_COMING_MESSAGE =
    'This transaction type is coming in Phase 2. Fuel Sale and Fuel Purchase are available now.';

export const SALE_PURCHASE_IMMUTABLE_MESSAGE =
    'Posted sales and purchases cannot be edited. Use reversal to correct, then create a new voucher.';

/** @deprecated Use SALE_PURCHASE_IMMUTABLE_MESSAGE */
export const PHASE1_EDIT_DELETE_MESSAGE = SALE_PURCHASE_IMMUTABLE_MESSAGE;

export const PHASE1_RPC_ERROR = 'Edit/delete temporarily disabled';

export function toastEditDeleteDisabled(
    toast: (opts: { variant?: 'destructive'; title: string; description: string }) => void
) {
    toast({
        variant: 'destructive',
        title: 'Edit / delete disabled',
        description: PHASE1_EDIT_DELETE_MESSAGE,
    });
}

export function assertPhase1CreateOnly(isEditMode: boolean): void {
    if (isEditMode) {
        throw new Error(PHASE1_EDIT_DELETE_MESSAGE);
    }
}
