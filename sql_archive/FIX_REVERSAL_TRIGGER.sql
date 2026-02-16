-- FIX: REVERSAL AND EXPENSE VALIDATION
-- Purpose: Allow REV- and EXP- vouchers to pass through the ledger check without a corresponding sub-ledger entry.

BEGIN;

CREATE OR REPLACE FUNCTION public.ensure_source_document_exists()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- 1. WHITELIST: Allowed types
    IF NEW.voucher_type NOT IN (
        'sale',
        'purchase',
        'receipt',
        'payment',
        'opening_balance',
        'transfer', 
        'journal'   
    ) THEN
        RAISE EXCEPTION 
            'INVALID VOUCHER TYPE: "%" is not permitted.',
            NEW.voucher_type
            USING HINT = 'Allowed types: sale, purchase, receipt, payment, opening_balance, transfer, journal';
    END IF;

    -- 2. BYPASS: If its a REVERSAL (REV-), we allow it to pass. 
    -- The reverse_transaction RPC ensures entries are balanced.
    IF NEW.voucher_no LIKE 'REV-%' THEN
        RETURN NEW;
    END IF;

    -- 3. BYPASS: Expense vouchers (EXP-) often don't have sub-ledger entries in 'payments'
    -- because they are direct GL postings.
    IF NEW.voucher_no LIKE 'EXP-%' THEN
        RETURN NEW;
    END IF;

    -- 4. SOURCE VALIDATION:
    IF NEW.voucher_type = 'sale' THEN
        IF NOT EXISTS (SELECT 1 FROM public.sales WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 'Source missing for sale voucher %', NEW.voucher_no;
        END IF;
    END IF;

    IF NEW.voucher_type IN ('receipt', 'payment') THEN
        IF NOT EXISTS (SELECT 1 FROM public.payments WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 'Source missing for payment voucher %', NEW.voucher_no;
        END IF;
    END IF;

    IF NEW.voucher_type = 'purchase' THEN
        IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 'Source missing for purchase voucher %', NEW.voucher_no;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

COMMIT;
