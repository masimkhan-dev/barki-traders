/**
 * Quick local check that .env exists and required Vite vars are set.
 * Production deploys must define these values in Vercel Project Settings.
 *
 * Run: node scripts/check-env.js
 */
import { readFileSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const envPath = resolve(root, '.env');

if (!existsSync(envPath)) {
  console.error('ERROR: .env file missing. For local dev, run: copy .env.example .env');
  process.exit(1);
}

const raw = readFileSync(envPath, 'utf8');
const vars = {};
for (const line of raw.split('\n')) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('#')) continue;
  const eq = trimmed.indexOf('=');
  if (eq === -1) continue;
  vars[trimmed.slice(0, eq).trim()] = trimmed.slice(eq + 1).trim();
}

const required = ['VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY'];
const placeholders = [
  'your-barki-anon-key',
  'YOUR-BARKI-PROJECT-REF',
  'your_project',
  'your_anon',
];

let ok = true;
for (const key of required) {
  const val = vars[key];
  if (!val) {
    console.error(`ERROR: Missing ${key} in .env`);
    ok = false;
    continue;
  }
  if (placeholders.some((p) => val.includes(p))) {
    console.error(`ERROR: ${key} still has a placeholder value`);
    ok = false;
  }
}

if (vars.VITE_CLIENT_SLUG) {
  console.log(`OK: VITE_CLIENT_SLUG=${vars.VITE_CLIENT_SLUG}`);
}

if (ok) {
  console.log('OK: .env has the required local Supabase variables');
  console.log(`URL: ${vars.VITE_SUPABASE_URL}`);
} else {
  process.exit(1);
}
