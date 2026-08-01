-- ============================================================================
-- Migration: 14_ROLLBACK_TRADING_MARGIN_WATERFALL.sql
-- Description: Safely drops the Trading Margin Waterfall feature objects.
--              Does NOT touch sales, purchases, ledger_entries, accounts,
--              inventory, AVCO, Trial Balance, Balance Sheet, or P&L.
-- ============================================================================

-- Drop RPCs first (they depend on the view)
DROP FUNCTION IF EXISTS public.get_trading_margin_by_fuel(date, date);
DROP FUNCTION IF EXISTS public.get_trading_margin_summary(date, date);

-- Drop the read-only view
DROP VIEW IF EXISTS public.v_sale_profit_waterfall;
