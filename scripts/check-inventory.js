import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';
dotenv.config({ path: '.env.local' });

const supabaseUrl = process.env.VITE_SUPABASE_URL;
const supabaseKey = process.env.VITE_SUPABASE_ANON_KEY;
const supabase = createClient(supabaseUrl, supabaseKey);

async function checkInventory() {
  console.log('Fetching inventory stock...');
  
  // 1. Fetch fuel types
  const { data: fuelTypes, error: ftError } = await supabase
    .from('fuel_types')
    .select('id, name, unit');
    
  if (ftError) {
    console.error('Error fetching fuel types:', ftError);
    return;
  }
  
  // 2. Fetch current stock from inventory table
  const { data: inventory, error: invError } = await supabase
    .from('inventory')
    .select('fuel_type_id, quantity');
    
  if (invError) {
    console.error('Error fetching inventory:', invError);
    return;
  }
  
  // 3. Map and display
  console.log('\n--- CURRENT STOCK ---');
  let hasStock = false;
  
  inventory.forEach(item => {
    const fuelType = fuelTypes.find(ft => ft.id === item.fuel_type_id);
    if (fuelType) {
      console.log(`- ${fuelType.name}: ${item.quantity} ${fuelType.unit}`);
      hasStock = true;
    }
  });
  
  if (!hasStock) {
    console.log('No stock records found in inventory.');
  }
  console.log('---------------------\n');
}

checkInventory();
