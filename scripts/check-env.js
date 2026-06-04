/**
 * Quick check that .env exists and required Vite vars are set.
 * Run: node scripts/check-env.js
 */
import { readFileSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const envPath = resolve(root, '.env');

if (!existsSync(envPath)) {
  console.error('❌ .env file missing. Run:  copy .env.example .env');
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
const placeholders = ['your-barki-anon-key', 'YOUR-BARKI-PROJECT-REF', 'your_project', 'your_anon'];

let ok = true;
for (const key of required) {
  const val = vars[key];
  if (!val) {
    console.error(`❌ Missing ${key} in .env`);
    ok = false;
    continue;
  }
  if (placeholders.some((p) => val.includes(p))) {
    console.error(`❌ ${key} still has placeholder value — paste real Supabase credentials`);
    ok = false;
  }
}

if (vars.VITE_CLIENT_SLUG) {
  console.log(`✓ VITE_CLIENT_SLUG=${vars.VITE_CLIENT_SLUG}`);
}

if (ok) {
  console.log('✓ .env looks ready for Barki Traders');
  console.log(`  URL: ${vars.VITE_SUPABASE_URL}`);
} else {
  process.exit(1);
}
