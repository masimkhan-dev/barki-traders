/**
 * Quick fuel stock audit — run from project root:
 *   node scripts/check-fuel-stock.mjs
 *   node scripts/check-fuel-stock.mjs PUR-20260523-001
 *
 * Needs .env with VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (or service role for full read).
 */

import { createClient } from '@supabase/supabase-js';
import { readFileSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, '..');

function loadEnv() {
  const env = {};
  for (const file of ['.env.local', '.env']) {
    const p = resolve(root, file);
    if (!existsSync(p)) continue;
    for (const line of readFileSync(p, 'utf8').split('\n')) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
  return env;
}

const voucherArg = process.argv[2] || 'PUR-20260523-001';
const env = loadEnv();
const url = env.VITE_SUPABASE_URL;
const key = env.SUPABASE_SERVICE_ROLE_KEY || env.VITE_SUPABASE_ANON_KEY;

if (!url || !key) {
  console.error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY in .env');
  process.exit(1);
}

const supabase = createClient(url, key);

function pad(s, n) {
  return String(s).padEnd(n);
}

async function main() {
  console.log('\n=== FUEL STOCK SNAPSHOT ===\n');

  const { data: fuels, error: ftErr } = await supabase
    .from('fuel_types')
    .select('id, name, unit')
    .eq('is_active', true)
    .order('name');

  if (ftErr) throw ftErr;

  const { data: purchases, error: pErr } = await supabase.from('purchases').select('fuel_type_id, quantity');
  if (pErr) throw pErr;

  const { data: sales, error: sErr } = await supabase.from('sales').select('fuel_type_id, quantity');
  if (sErr) throw sErr;

  const { data: inventory, error: iErr } = await supabase.from('inventory').select('fuel_type_id, quantity, avg_cost, last_updated');
  if (iErr) throw iErr;

  const sumBy = (rows, id) => (rows || []).filter(r => r.fuel_type_id === id).reduce((a, r) => a + Number(r.quantity || 0), 0);

  console.log(
    pad('FUEL', 12),
    pad('PURCHASES', 12),
    pad('SALES', 12),
    pad('COMPUTED', 12),
    pad('INVENTORY', 12),
    pad('DRIFT', 10),
    'OK?'
  );
  console.log('-'.repeat(82));

  for (const ft of fuels || []) {
    const purchased = sumBy(purchases, ft.id);
    const sold = sumBy(sales, ft.id);
    const computed = purchased - sold;
    const invRow = (inventory || []).find(i => i.fuel_type_id === ft.id);
    const cached = Number(invRow?.quantity ?? 0);
    const drift = Math.abs(computed - cached);
    const ok = drift < 0.001 ? 'YES' : 'NO';

    console.log(
      pad(ft.name, 12),
      pad(purchased.toLocaleString(), 12),
      pad(sold.toLocaleString(), 12),
      pad(computed.toLocaleString(), 12),
      pad(cached.toLocaleString(), 12),
      pad(drift.toLocaleString(), 10),
      ok
    );
  }

  console.log('\n=== LAST EDIT VOUCHER:', voucherArg, '===\n');

  const { data: purchase, error: purErr } = await supabase
    .from('purchases')
    .select('*')
    .eq('voucher_no', voucherArg)
    .maybeSingle();

  if (purErr) throw purErr;

  const { data: sale } = await supabase.from('sales').select('*').eq('voucher_no', voucherArg).maybeSingle();

  const { data: ledger } = await supabase
    .from('ledger_entries')
    .select('posting_date, account_id, party_id, debit_amount, credit_amount, narration')
    .eq('voucher_no', voucherArg);

  if (purchase) {
    console.log('purchases row:', {
      voucher_no: purchase.voucher_no,
      date: purchase.purchase_date,
      quantity: purchase.quantity,
      rate: purchase.rate_per_unit,
      total: purchase.total_amount,
      fuel_type_id: purchase.fuel_type_id,
      party_id: purchase.party_id,
    });
  } else {
    console.log('purchases row: MISSING (ledger-only voucher?)');
  }

  if (sale) {
    console.log('sales row:', { quantity: sale.quantity, total: sale.total_amount });
  }

  console.log('ledger lines:', (ledger || []).length);
  for (const le of ledger || []) {
    console.log(
      ' ',
      le.posting_date,
      'Dr', le.debit_amount,
      'Cr', le.credit_amount,
      le.narration?.slice(0, 40)
    );
  }

  const { data: repair, error: repairErr } = await supabase.rpc('repair_inventory_from_transactions');
  if (!repairErr && repair) {
    console.log('\nrepair_inventory_from_transactions:', repair);
  } else if (repairErr) {
    console.log('\n(repair_inventory_from_transactions RPC not deployed yet — run migration 20260523110000)');
  }

  console.log('\nDone.\n');
}

main().catch(e => {
  console.error(e);
  process.exit(1);
});
