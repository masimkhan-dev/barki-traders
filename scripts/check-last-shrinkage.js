/**
 * Script to check the last recorded Fuel Shrinkage (loss) from Supabase.
 *
 * Usage:
 *   node scripts/check-last-shrinkage.js
 */
import { readFileSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { createClient } from '@supabase/supabase-js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const envPath = resolve(root, '.env');

if (!existsSync(envPath)) {
  console.error('❌ ERROR: .env file missing. Ensure .env exists in project root.');
  process.exit(1);
}

// Simple .env parser
const raw = readFileSync(envPath, 'utf8');
const vars = {};
for (const line of raw.split('\n')) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('#')) continue;
  const eq = trimmed.indexOf('=');
  if (eq === -1) continue;
  vars[trimmed.slice(0, eq).trim()] = trimmed.slice(eq + 1).trim();
}

const supabaseUrl = vars.VITE_SUPABASE_URL;
const supabaseKey = vars.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseKey) {
  console.error('❌ ERROR: Missing VITE_SUPABASE_URL or VITE_SUPABASE_ANON_KEY in .env');
  process.exit(1);
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function checkLastShrinkage() {
  console.log('🔍 Fetching last recorded shrinkage (fuel loss) entries...\n');

  // Query 1: Inventory Events (Direct Fuel Loss linked to Fuel Type)
  const { data: invEvents, error: invErr } = await supabase
    .from('inventory_events')
    .select(`
      id,
      voucher_no,
      event_type,
      quantity,
      unit_cost,
      total_cost,
      stock_after,
      narration,
      created_at,
      fuel_types (
        id,
        name
      )
    `)
    .or('voucher_no.ilike.SHR%,event_type.eq.ADJUSTMENT')
    .order('created_at', { ascending: false })
    .limit(5);

  if (invErr) {
    console.error('⚠️ Inventory Events query error:', invErr.message);
  } else if (invEvents && invEvents.length > 0) {
    console.log('📌 === LAST SHRINKAGE FROM INVENTORY EVENTS ===');
    const latest = invEvents[0];
    const fuelName = latest.fuel_types ? `${latest.fuel_types.name} (${latest.fuel_types.code})` : 'Unknown Fuel';
    const qtyLost = Math.abs(Number(latest.quantity));
    const rate = Number(latest.unit_cost);
    const totalCost = Math.abs(Number(latest.total_cost));

    console.log(`• Fuel Type        : ${fuelName}`);
    console.log(`• Voucher No       : ${latest.voucher_no}`);
    console.log(`• Quantity Lost    : ${qtyLost} Liters`);
    console.log(`• Rate per Liter   : PKR ${rate.toLocaleString()}`);
    console.log(`• Total Loss Amount: PKR ${totalCost.toLocaleString()}`);
    console.log(`• Stock Remaining  : ${latest.stock_after} Liters`);
    console.log(`• Reason/Narration : ${latest.narration || 'N/A'}`);
    console.log(`• Date Recorded    : ${new Date(latest.created_at).toLocaleString()}`);
    console.log('--------------------------------------------\n');
  } else {
    console.log('ℹ️ No shrinkage recorded in inventory_events table.\n');
  }

  // Query 2: Ledger Entries (Financial Vouchers for Shrinkage)
  const { data: ledgerEntries, error: ledgerErr } = await supabase
    .from('ledger_entries')
    .select(`
      id,
      voucher_no,
      voucher_type,
      posting_date,
      debit_amount,
      credit_amount,
      quantity,
      rate,
      narration,
      created_at,
      accounts (
        name,
        slug
      )
    `)
    .eq('voucher_type', 'shrinkage')
    .order('created_at', { ascending: false })
    .limit(5);

  if (ledgerErr) {
    console.error('⚠️ Ledger Entries query error:', ledgerErr.message);
  } else if (ledgerEntries && ledgerEntries.length > 0) {
    console.log('📊 === RECENT SHRINKAGE LEDGER VOUCHERS ===');
    ledgerEntries.forEach((entry, idx) => {
      console.log(`[${idx + 1}] Voucher: ${entry.voucher_no} | Date: ${entry.posting_date}`);
      console.log(`    Account: ${entry.accounts?.name || 'N/A'} | Debit: PKR ${entry.debit_amount} | Credit: PKR ${entry.credit_amount}`);
      console.log(`    Qty: ${entry.quantity || 0} L @ PKR ${entry.rate || 0} | Narration: ${entry.narration}`);
    });
  } else {
    console.log('ℹ️ No shrinkage vouchers found in ledger_entries table.\n');
  }
}

checkLastShrinkage().catch((err) => {
  console.error('❌ Script failed:', err);
});
