import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { debugLog } from '@/lib/debug-log';

interface FuelStock {
  fuel_type_id: string;
  fuel_type_name: string;
  fuel_type_unit: string;
  total_purchased: number;
  total_sold: number;
  current_stock: number;
}

export function useInventory() {
  return useQuery({
    queryKey: ['calculated-inventory'],
    queryFn: async () => {
      // Fetch all fuel types
      const { data: fuelTypes, error: ftError } = await supabase
        .from('fuel_types')
        .select('id, name, unit')
        .eq('is_active', true)
        .order('name');

      if (ftError) throw ftError;

      // Fetch all purchases grouped by fuel type
      const { data: purchases, error: pError } = await supabase
        .from('purchases')
        .select('fuel_type_id, quantity')
        .eq('is_reversed', false);

      if (pError) throw pError;

      // Fetch all sales grouped by fuel type
      const { data: sales, error: sError } = await supabase
        .from('sales')
        .select('fuel_type_id, quantity')
        .eq('is_reversed', false);

      if (sError) throw sError;

      // Fetch current stock from the inventory table (Disposable Cache)
      const { data: currentStock, error: iError } = await supabase
        .from('inventory')
        .select('fuel_type_id, quantity');

      if (iError) throw iError;

      // Calculate stock for each fuel type
      const stockMap: Record<string, FuelStock> = {};

      // Initialize with fuel types
      fuelTypes?.forEach(ft => {
        stockMap[ft.id] = {
          fuel_type_id: ft.id,
          fuel_type_name: ft.name,
          fuel_type_unit: ft.unit,
          total_purchased: 0,
          total_sold: 0,
          current_stock: 0,
        };
      });

      // Sum purchases
      purchases?.forEach(p => {
        if (stockMap[p.fuel_type_id]) {
          stockMap[p.fuel_type_id].total_purchased += Number(p.quantity);
        }
      });

      // Sum sales
      sales?.forEach(s => {
        if (stockMap[s.fuel_type_id]) {
          stockMap[s.fuel_type_id].total_sold += Number(s.quantity);
        }
      });

      // Set current stock from inventory cache.
      // Opening stock is stored directly in inventory before daily vouchers exist,
      // so do not overwrite it with purchase-minus-sale totals here.
      currentStock?.forEach(item => {
        if (stockMap[item.fuel_type_id]) {
          stockMap[item.fuel_type_id].current_stock = Number(item.quantity);
        }
      });

      const result = Object.values(stockMap);

      // #region agent log
      const mismatches = result
        .map(s => ({
          fuel: s.fuel_type_name,
          computed: s.total_purchased - s.total_sold,
          cached: s.current_stock,
          drift: Math.abs(s.total_purchased - s.total_sold - s.current_stock),
        }))
        .filter(m => m.drift > 0.001);
      if (mismatches.length > 0) {
        debugLog(
          'useInventory.ts:queryFn',
          'inventory drift detected',
          { mismatchCount: mismatches.length, samples: mismatches.slice(0, 3) },
          'B,E',
          'pre-fix'
        );
      }
      // #endregion

      return result;
    },
    staleTime: 30000, // Cache for 30 seconds
  });
}

export function useStockCheck(fuelTypeId: string | undefined) {
  const { data: inventory } = useInventory();
  
  if (!fuelTypeId || !inventory) return { available: 0, hasStock: true };
  
  const fuelStock = inventory.find(i => i.fuel_type_id === fuelTypeId);
  const available = fuelStock?.current_stock || 0;
  
  return {
    available,
    hasStock: available > 0,
    checkQuantity: (qty: number) => available >= qty,
  };
}
