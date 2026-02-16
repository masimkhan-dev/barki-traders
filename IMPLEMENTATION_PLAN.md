# 🚀 Implementation Plan: System Stabilization & Dashboard Fix

## 📋 Current Status
- **System Version**: V10.2 (Production)
- **Active Task**: Fixing Dashboard Analytics & Stock Accuracy
- **Pending File**: `FIX_DASHBOARD_AND_STOCK.sql`

## 🗓️ Phase 1: Immediate Stabilization (The "Now" Steps)
1.  **Apply Analytics Fix (`FIX_DASHBOARD_AND_STOCK.sql`)**
    *   **Goal**: Update `get_dashboard_v10_analytics` and `get_stock_movement` functions.
    *   **Why**: The Frontend is already calling these functions. We need to ensure the Database logic matches the Frontend expectation for accurate reporting.
    
2.  **Run Health Check (`supabase/scripts/run_health_check.sql`)**
    *   **Goal**: Scan for "Orphan Sales" (Sales not in Ledger) and "Unbalanced Vouchers".
    *   **Why**: To ensure the foundations are solid before we trust the dashboard numbers.

3.  **Browser Verification**
    *   **Goal**: visually verify the Dashboard loads without errors.
    *   **Why**: Confirm the "Spinners" disappear and real numbers (Sales, Purchases, Receivables) appear.

## 🗓️ Phase 2: Cleanup & Hardening
1.  **Archive Temporary Scripts**:
    *   Move the 50+ `FIX_...sql` files into an `archive/` folder.
    *   Keep only the **Canonical Migration Chain** in `supabase/migrations`.
    
2.  **Documentation**:
    *   Update `MUNSHI_OWNER_GUIDE.md` if any workflows verify.

## 🚀 Execution Command
Shall we proceed with **Phase 1** starting with applying the Dashboard SQL fix?
