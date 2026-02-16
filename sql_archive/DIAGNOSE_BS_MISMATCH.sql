-- DIAGNOSE BALANCE SHEET MISMATCH
-- Purpose: Find the exact source of the Rs 120,980 imbalance.

WITH AssetSide AS (
    SELECT COALESCE(SUM(balance), 0) as total_assets
    FROM get_financial_position('2026-02-05')
    WHERE category = 'ASSETS'
),
LiabilitySide AS (
    SELECT COALESCE(SUM(balance), 0) as total_liabilities
    FROM get_financial_position('2026-02-05')
    WHERE category = 'LIABILITIES'
),
EquitySide AS (
    SELECT COALESCE(SUM(balance), 0) as total_equity
    FROM get_financial_position('2026-02-05')
    WHERE category = 'EQUITY'
)
SELECT 
    (SELECT total_assets FROM AssetSide) as assets,
    (SELECT total_liabilities FROM LiabilitySide) as liabilities,
    (SELECT total_equity FROM EquitySide) as equity,
    (SELECT total_liabilities FROM LiabilitySide) + (SELECT total_equity FROM EquitySide) as total_l_and_e,
    (SELECT total_assets FROM AssetSide) - ((SELECT total_liabilities FROM LiabilitySide) + (SELECT total_equity FROM EquitySide)) as difference;
