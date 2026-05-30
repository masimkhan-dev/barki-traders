# Phase 1 — Read-only edit/delete

Temporary safety: all voucher **edit** and **delete** paths are disabled. **Create** and **read** flows are unchanged.

## Database (apply migration)

`supabase/migrations/20260523120000_phase1_disable_edit_delete.sql`

| RPC | Behavior |
|-----|----------|
| `edit_sale_transaction` | Returns `Edit/delete temporarily disabled` |
| `edit_purchase_transaction` | Same |
| `upsert_purchase_transaction` | Same |
| `cancel_sale_transaction` | Same |
| `cancel_purchase_transaction` | Same |
| `delete_transaction_safely` | Same |
| `reverse_transaction_safely` | Same |
| `reverse_transaction` (if present) | Same |

Also: `REVOKE UPDATE, DELETE` on `sales`, `purchases`, `ledger_entries` for `authenticated`.

**Unchanged:** `post_sale_transaction`, `post_purchase_transaction`, INSERT triggers (`sync_sale_v11`, `sync_purchase_v11`), reporting RPCs.

## Frontend files touched

| File | Change |
|------|--------|
| `src/lib/phase1-readonly.ts` | Shared message + helpers |
| `src/pages/ManageTransactions.tsx` | Block `?edit=`, remove edit/delete UI, guard mutations |
| `src/pages/RoznamchaV3.tsx` | Disabled edit/delete actions |
| `src/pages/BusinessReports.tsx` | Disabled sale/purchase edit links |
| `src/pages/Roznamcha.tsx` | Disabled edit/delete/reversal (legacy) |
| `src/pages/RoznamchaV2.tsx` | Disabled edit links (legacy) |
| `src/pages/AccountStatement.tsx` | Disabled reversal control |
| `src/pages/Expenses.tsx` | Strip `?edit=` on redirect |
| `src/components/modals/ReversalModal.tsx` | No RPC; shows disabled message |
| `src/components/modals/V11EditVoucher.tsx` | No RPC; shows disabled message |

## Rollback (Phase 2)

1. Revert or replace `20260523120000_phase1_disable_edit_delete.sql` with restored RPC bodies from `20260521120000_edit_delete_transaction_compat.sql` / `20260523110000_upsert_purchase_repair_inventory.sql`.
2. Re-grant `UPDATE, DELETE` on core tables to `authenticated` if required.
3. Re-enable frontend edit routes and modals.
