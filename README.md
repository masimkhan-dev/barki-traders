# Barki Traders — Fuel Trust Ledger

Enterprise fuel accounting: double-entry ledger, inventory (AVCO), sales/purchases, and financial reports.

## Stack

- React 18 + TypeScript + Vite
- Tailwind CSS + shadcn/ui
- Supabase (PostgreSQL + Auth)

## Setup

1. **Clone**

   ```bash
   git clone https://github.com/masimkhan-dev/barki-traders.git
   cd barki-traders
   npm install
   ```

2. **Environment**

   ```bash
   copy .env.example .env
   ```

   Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` from your Barki Supabase project.

3. **Database** (new Supabase project only)

   Run once in **SQL Editor**:

   `supabase/migrations/00_MASTER_BASELINE_BARKI_TRADERS.sql`

   Then assign admin:

   ```sql
   INSERT INTO public.user_roles (user_id, role)
   VALUES ('YOUR-AUTH-USER-UUID', 'admin');
   ```

4. **Run**

   ```bash
   npm run dev
   ```

## Branding

Edit `src/lib/client-config.ts` for business name, currency, and colors.

## Scripts

| Command | Description |
|---------|-------------|
| `npm run dev` | Development server |
| `npm run build` | Production build |
| `npm run check:env` | Verify `.env` is configured |
