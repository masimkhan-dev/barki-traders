# Database migrations — Barki Traders

This folder is the **only** migration source for the Barki Traders Supabase project.

## Apply on a new Supabase project

1. Open **Supabase Dashboard → SQL Editor**
2. Run the full contents of `00_MASTER_BASELINE_BARKI_TRADERS.sql` once
3. Create an admin user in **Authentication**, then:

```sql
INSERT INTO public.user_roles (user_id, role)
VALUES ('YOUR-USER-UUID', 'admin');
```

## Do not

- Re-apply old archived migrations from git history (removed intentionally)
- Run scripts in `supabase/scripts/` unless you know they apply to Barki

## Adding changes

Add new numbered files after baseline, e.g. `01_barki_reports.sql`, instead of one-off `FIX_*.sql` files.
