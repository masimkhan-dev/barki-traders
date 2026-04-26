-- ============================================================
-- FIX 1: get_profit_loss_v13
-- BUG: Accounts with zero net activity still returned
-- FIX: Added HAVING clause to exclude zero-amount rows
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_profit_loss_v13(p_start_date date, p_end_date date)
RETURNS TABLE(section_code text, section_name text, account_name text, amount numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        CASE
            WHEN a.account_type = 'income'                    THEN '10'
            WHEN a.slug = 'cogs' OR a.code = '4100'          THEN '20'
            WHEN a.sub_category = 'operating_expense'         THEN '30'
            WHEN a.sub_category = 'utility_bill'              THEN '40'
            WHEN a.sub_category = 'salary'                    THEN '50'
            ELSE '90'
        END::text AS section_code,

        CASE
            WHEN a.account_type = 'income'           THEN 'Revenue'
            WHEN a.slug = 'cogs' OR a.code = '4100'  THEN 'Cost of Sales'
            ELSE INITCAP(COALESCE(REPLACE(a.sub_category, '_', ' '), 'Other Expense'))
        END::text AS section_name,

        a.name::text AS account_name,

        ROUND(
            CASE
                WHEN a.account_type = 'income'
                    THEN SUM(le.credit_amount - le.debit_amount)
                ELSE
                    SUM(le.debit_amount - le.credit_amount)
            END, 2
        ) AS amount

    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date BETWEEN p_start_date AND p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)

    GROUP BY a.id, a.name, a.account_type, a.sub_category, a.slug, a.code

    -- BUG FIX: Remove zero-amount rows (were causing ghost lines in P&L)
    HAVING
        ROUND(
            CASE
                WHEN a.account_type = 'income'
                    THEN SUM(le.credit_amount - le.debit_amount)
                ELSE
                    SUM(le.debit_amount - le.credit_amount)
            END, 2
        ) != 0

    ORDER BY section_code ASC, amount DESC;
END;
$function$;


-- ============================================================
-- FIX 2: get_trial_balance_v2
-- BUG: WHERE clause on LEFT JOIN was turning it into INNER JOIN
-- FIX: Move is_reversed filter INTO the JOIN ON clause.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_trial_balance_v2(
    p_start_date date DEFAULT NULL::date,
    p_end_date   date DEFAULT NULL::date
)
RETURNS TABLE(
    account_code    text,
    account_name    text,
    account_type    text,
    opening_balance numeric,
    debit_total     numeric,
    credit_total    numeric,
    net_movement    numeric,
    debit_balance   numeric,
    credit_balance  numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY
    WITH all_entities AS (
        -- Standard Accounts
        SELECT
            a.id, 'account'::text as etype,
            a.code::text as ac,
            a.name::text as an,
            a.account_type::text as at,
            0::NUMERIC as ob
        FROM public.accounts a
        WHERE COALESCE(a.slug, '') NOT IN ('ar', 'ap', 'party_control')

        UNION ALL

        -- Party Ledgers (Customers & Suppliers)
        SELECT
            p.id, 'party'::text as etype,
            (CASE WHEN p.type = 'customer' THEN '1100-' ELSE '2100-' END
             || LEFT(p.id::text, 8))::text as ac,
            p.name::text as an,
            (CASE WHEN p.type = 'customer' THEN 'asset' ELSE 'liability' END)::text as at,
            p.opening_balance as ob
        FROM public.parties p
    ),

    ledger_sum AS (
        SELECT
            ae.id,
            ae.etype,
            SUM(
                CASE WHEN p_start_date IS NOT NULL
                          AND le.posting_date < p_start_date
                     THEN le.debit_amount - le.credit_amount
                     ELSE 0
                END
            ) AS post_op,
            SUM(
                CASE WHEN (p_start_date IS NULL OR le.posting_date >= p_start_date)
                          AND (p_end_date IS NULL OR le.posting_date <= p_end_date)
                     THEN le.debit_amount
                     ELSE 0
                END
            ) AS dr,
            SUM(
                CASE WHEN (p_start_date IS NULL OR le.posting_date >= p_start_date)
                          AND (p_end_date IS NULL OR le.posting_date <= p_end_date)
                     THEN le.credit_amount
                     ELSE 0
                END
            ) AS cr

        FROM all_entities ae
        LEFT JOIN public.ledger_entries le ON
            (
                (ae.etype = 'account' AND le.account_id = ae.id)
                OR
                (ae.etype = 'party'   AND le.party_id   = ae.id)
            )
            AND (le.is_reversed IS NULL OR le.is_reversed = false)

        GROUP BY ae.id, ae.etype
    ),

    results AS (
        SELECT
            ae.ac, ae.an, ae.at,
            (ae.ob + COALESCE(ls.post_op, 0))                            AS op_bal,
            COALESCE(ls.dr, 0)                                            AS dr_total,
            COALESCE(ls.cr, 0)                                            AS cr_total,
            (COALESCE(ls.dr, 0) - COALESCE(ls.cr, 0))                    AS movement,
            (ae.ob + COALESCE(ls.post_op, 0)
                   + COALESCE(ls.dr, 0)
                   - COALESCE(ls.cr, 0))                                  AS final_bal
        FROM all_entities ae
        LEFT JOIN ledger_sum ls ON ae.id = ls.id AND ae.etype = ls.etype
    )

    SELECT
        ac, an, at,
        ROUND(COALESCE(op_bal,   0), 2),
        ROUND(COALESCE(dr_total, 0), 2),
        ROUND(COALESCE(cr_total, 0), 2),
        ROUND(COALESCE(movement, 0), 2),
        CASE WHEN final_bal > 0 THEN ROUND(final_bal,       2) ELSE 0 END,
        CASE WHEN final_bal < 0 THEN ROUND(ABS(final_bal),  2) ELSE 0 END
    FROM results
    WHERE dr_total != 0 OR cr_total != 0 OR op_bal != 0
    ORDER BY
        CASE
            WHEN at = 'asset'     THEN 1
            WHEN at = 'liability' THEN 2
            WHEN at = 'equity'    THEN 3
            WHEN at = 'income'    THEN 4
            ELSE 5
        END,
        ac;
END;
$function$;


-- ============================================================
-- FIX 3: get_financial_position_v13
-- BUG: Net Profit calculation formula was incorrect
-- FIX: Properly separate income vs expense contributions
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_financial_position_v13(p_date date)
RETURNS TABLE(
    section_code text,
    section_name text,
    group_name   text,
    account_name text,
    balance      numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_net_profit NUMERIC;
BEGIN
    SELECT COALESCE(
        SUM(
            CASE
                WHEN a.account_type = 'income'
                    THEN le.credit_amount - le.debit_amount
                ELSE
                    -(le.debit_amount - le.credit_amount)
            END
        ), 0)
    INTO v_net_profit
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    RETURN QUERY
    WITH account_balances AS (
        SELECT
            a.id,
            a.name,
            a.account_type,
            a.sub_category,
            a.code,
            COALESCE(SUM(le.debit_amount - le.credit_amount), 0) AS net_debit
        FROM accounts a
        LEFT JOIN ledger_entries le
            ON le.account_id = a.id
           AND le.posting_date <= p_date
           AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY a.id, a.name, a.account_type, a.sub_category, a.code
    )
    SELECT * FROM (
        -- A. ASSETS
        SELECT
            CASE WHEN b.sub_category = 'fixed_asset' THEN '15' ELSE '10' END AS s_code,
            CASE WHEN b.sub_category = 'fixed_asset'
                 THEN 'Non-Current Assets'::TEXT
                 ELSE 'Current Assets'::TEXT
            END AS s_name,
            CASE
                WHEN b.code = '1100' THEN 'Trade Receivables (Lena)'::TEXT
                ELSE INITCAP(REPLACE(COALESCE(b.sub_category, 'general'), '_', ' '))
            END AS g_name,
            b.name::TEXT AS a_name,
            b.net_debit   AS bal
        FROM account_balances b
        WHERE b.account_type = 'asset'
          AND (b.net_debit != 0 OR b.code IN ('1000', '1010'))

        UNION ALL

        -- B. LIABILITIES
        SELECT
            '20',
            'Liabilities',
            CASE
                WHEN b.code = '2000' THEN 'Trade Payables (Dena)'::TEXT
                ELSE INITCAP(REPLACE(COALESCE(b.sub_category, 'general'), '_', ' '))
            END,
            b.name::TEXT,
            -b.net_debit
        FROM account_balances b
        WHERE b.account_type = 'liability' AND b.net_debit != 0

        UNION ALL

        -- C. EQUITY
        SELECT
            '30',
            'Equity',
            'Capital & Ownership'::TEXT,
            b.name::TEXT,
            -b.net_debit
        FROM account_balances b
        WHERE b.account_type = 'equity' AND b.net_debit != 0

        UNION ALL

        -- D. NET PROFIT / LOSS (retained in Equity)
        SELECT
            '30',
            'Equity',
            'Net Profit/Loss'::TEXT,
            'Current Period Performance'::TEXT,
            v_net_profit

    ) q
    ORDER BY q.s_code, q.g_name, q.a_name;
END;
$function$;
