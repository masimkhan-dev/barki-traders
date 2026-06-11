# Database Migrations - Barki Traders

This folder is the migration source for the Barki Traders Supabase project.

## Production release guidance

- Current linked Supabase project ref: `afuhxibzrjazwdcuzthq`.
- For a brand-new Supabase project, run `00_MASTER_BASELINE_FINAL_NEW_CLIENT.sql` once.
- For an existing project that already has the original baseline, apply only the reviewed numbered patch files in order.
- Do not run both baseline files on the same database.
- Do not re-apply archived migrations from git history.

## Dashboard analytics (read-only charts)

If the Dashboard shows **"Could not find the function ... in the schema cache"**:

1. Supabase Dashboard → **SQL Editor**
2. Run the full file `07_DASHBOARD_ANALYTICS_READONLY.sql`
3. Then run `08_GRANT_DASHBOARD_ANALYTICS.sql`
4. Hard-refresh the app (Ctrl+Shift+R)

Verify functions exist:

```sql
SELECT routine_name
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name LIKE 'get_dashboard_%'
ORDER BY routine_name;
```

You should see 8 functions.

## Safety notes

- `05_FIX_AVCO_AND_REPAIR_INVENTORY_GL.sql` defines `repair_inventory_gl_from_wac()` but does not auto-run it.
- Run repair functions manually only after a database backup and operator approval.
- Avoid one-off `FIX_*.sql` changes after this release; add the next numbered migration with a clear purpose.

## Admin bootstrap

After creating the first auth user, assign the admin role:

```sql
INSERT INTO public.user_roles (user_id, role)
VALUES ('YOUR-USER-UUID', 'admin');
```
