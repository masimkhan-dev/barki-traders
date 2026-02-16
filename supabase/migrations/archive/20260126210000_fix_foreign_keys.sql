-- =================================================================
-- FIX MISSING FOREIGN KEYS
-- Purpose: Add missing FK constraints for fuel_types in sales/purchases
-- Reason: Frontend fails with 400 Bad Request on joins
-- =================================================================

BEGIN;

-- 1. FIX SALES TABLE
ALTER TABLE public.sales 
    DROP CONSTRAINT IF EXISTS fk_sales_fuel_type;

ALTER TABLE public.sales
    ADD CONSTRAINT fk_sales_fuel_type
    FOREIGN KEY (fuel_type_id)
    REFERENCES public.fuel_types(id)
    ON DELETE RESTRICT;

-- 2. FIX PURCHASES TABLE
ALTER TABLE public.purchases
    DROP CONSTRAINT IF EXISTS fk_purchases_fuel_type;

ALTER TABLE public.purchases
    ADD CONSTRAINT fk_purchases_fuel_type
    FOREIGN KEY (fuel_type_id)
    REFERENCES public.fuel_types(id)
    ON DELETE RESTRICT;

COMMIT;
