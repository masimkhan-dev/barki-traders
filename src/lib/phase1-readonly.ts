/** Phase 1: temporary read-only for voucher edit/delete paths. */
export const PHASE1_EDIT_DELETE_MESSAGE =
    'Edit and delete are temporarily disabled. Create a correcting entry or contact admin.';

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
