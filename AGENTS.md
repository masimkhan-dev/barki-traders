# AI Agent Guide for Fuel Trust Ledger

## Purpose
This file helps AI coding agents understand the repository quickly and follow the project’s conventions.

## Project overview
- Frontend: React 18 + TypeScript + Vite
- Styling: Tailwind CSS, Shadcn/UI, Tailwind Typography
- API/Backend: Supabase client from the browser plus SQL/RPC stored procedures
- Architecture: Single-page app with pages, components, contexts, and utility libraries
- Database schema: single bootstrap `00_MASTER_BASELINE_BARKI_TRADERS.sql` in `supabase/migrations/` and `sql_archive/`

## Key directories
- `src/` — main application code
  - `src/pages/` — page-level routes and report screens
  - `src/components/` — reusable UI components and modals
  - `src/contexts/` — app-wide context providers like auth
  - `src/lib/` — shared utilities, formatting, and Supabase client
  - `src/integrations/supabase/` — Supabase client wrapper and typed DB schema
- `public/` — static assets
- `supabase/` — Supabase project config, migrations, and scripts
- `sql_archive/` — copy of the Barki master baseline SQL (see `supabase/migrations/README.md`)

## Build and validation commands
- `npm install`
- `npm run dev` — start the app locally
- `npm run build` — production build
- `npm run lint` — lint the repository

## Environment requirements
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`

## Important patterns
- Uses `@/` alias for imports from `src/`
- Supabase client is created in `src/lib/supabase.ts` and re-exported from `src/integrations/supabase/client.ts`
- Auth and session state are managed in `src/contexts/AuthContext.tsx`
- Many pages call Supabase RPC functions such as `reverse_transaction`, `get_trial_balance_v2`, and `edit_sale_transaction`
- UI is built with Tailwind utility classes and shadcn-inspired component wrappers
- Form validation often uses `react-hook-form` and `zod`

## Guidance for AI agents
- Preserve the existing accounting and ledger semantics when editing financial flow or reports.
- Keep UI changes modular; update components and pages without broad rewrites.
- Prefer type-safe changes with TypeScript and avoid weakening `any` unless absolutely necessary.
- Do not add or assume a separate Node/Express backend; the repository is a frontend client that talks to Supabase.
- When database logic is needed, start from `supabase/migrations/00_MASTER_BASELINE_BARKI_TRADERS.sql`; add new numbered SQL files for Barki-only changes.

## Useful docs
- Project summary and setup: [README.md](README.md)

## When you are unsure
- Ask for clarification before refactoring major reports, voucher flows, or accounting logic.
- Avoid changing financial formulas or report SQL without an explicit ticket or test coverage.
