import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { debugLog } from '@/lib/debug-log';

interface FuelStock {
  fuel_type_id: string;
  fuel_type_name: string;
  fuel_type_unit: string;
  total_purchased: number;
  total_sold: number;
  total_shrinkage: number;
  current_stock: number;
}

export function useInventory() {
  return useQuery({
    queryKey: ['calculated-inventory'],
    queryFn: async () => {
      // Fetch all active fuel types
      const { data: fuelTypes, error: ftError } = await supabase
        .from('fuel_types')
        .select('id, name, unit')
        .eq('is_active', true)
        .order('name');

      if (ftError) throw ftError;

      // Fetch all active purchases grouped by fuel type
      const { data: purchases, error: pError } = await supabase
        .from('purchases')
        .select('fuel_type_id, quantity')
        .eq('is_reversed', false);

      if (pError) throw pError;

      // Fetch all active sales grouped by fuel type
      const { data: sales, error: sError } = await supabase
        .from('sales')
        .select('fuel_type_id, quantity')
        .eq('is_reversed', false);

      if (sError) throw sError;

      // Fetch all shrinkage / inventory events
      const { data: inventoryEventsData, error: ieError } = await (supabase.from as any)('inventory_events')
        .select('fuel_type_id, quantity');

      if (ieError) throw ieError;

      const inventoryEvents = inventoryEventsData as Array<{ fuel_type_id: string; quantity: number }> | null;

      // Fetch current stock from the inventory table
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
          total_shrinkage: 0,
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

      // Sum shrinkage loss
      inventoryEvents?.forEach(ie => {
        if (stockMap[ie.fuel_type_id]) {
          stockMap[ie.fuel_type_id].total_shrinkage += Math.abs(Number(ie.quantity));
        }
      });

      // Set current stock from inventory table
      currentStock?.forEach(item => {
        if (stockMap[item.fuel_type_id]) {
          stockMap[item.fuel_type_id].current_stock = Number(item.quantity);
        }
      });

      const result = Object.values(stockMap);

      // Log genuine inventory drift (considering purchases, sales, shrinkage & cached stock)
      const mismatches = result
        .map(s => {
          const computed = s.total_purchased - s.total_sold - s.total_shrinkage;
          const drift = Math.abs(computed - s.current_stock);
          return {
            fuel: s.fuel_type_name,
            computed,
            cached: s.current_stock,
            drift,
          };
        })
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

      return result;
    },
    staleTime: 30000, // Cache for 30 seconds
  });
}

export function useStockCheck(fuelTypeId: string | undefined) {
  const { data: inventory, isLoading } = useInventory();
  
  if (!fuelTypeId || isLoading || !inventory) {
    return { available: 0, hasStock: false, checkQuantity: () => false };
  }
  
  const fuelStock = inventory.find(i => i.fuel_type_id === fuelTypeId);
  const available = fuelStock?.current_stock || 0;
  
  return {
    available,
    hasStock: available > 0,
    checkQuantity: (qty: number) => available >= qty,
  };
}
