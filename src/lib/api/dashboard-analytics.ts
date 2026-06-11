import { useQuery } from '@tanstack/react-query';
import { format, startOfMonth, startOfYear, subDays } from 'date-fns';
import { supabase } from '@/integrations/supabase/client';

export const ANALYTICS_STALE_TIME = 60_000;

export type DateRangePreset = '7D' | '30D' | 'MTD' | 'YTD';

export interface SalesPurchasesTrendRow {
  tx_date: string;
  sales_amount: number;
  purchases_amount: number;
}

export interface CashFlowTrendRow {
  tx_date: string;
  cash_in: number;
  cash_out: number;
  net_cash_flow: number;
}

export interface StockByFuelRow {
  fuel_type_id: string;
  fuel_name: string;
  unit: string;
  quantity: number;
  avg_cost: number;
  stock_value: number;
}

export interface ReceivablesPayablesRow {
  receivables: number;
  payables: number;
  net_position: number;
}

export interface TopCustomerRow {
  party_id: string;
  party_name: string;
  outstanding_amount: number;
}

export interface TopSupplierRow {
  party_id: string;
  party_name: string;
  payable_amount: number;
}

export interface ProfitTrendRow {
  tx_date: string;
  income: number;
  expense: number;
  gross_profit: number;
}

export interface FuelQuantitySoldRow {
  fuel_type_id: string;
  fuel_name: string;
  unit: string;
  quantity_sold: number;
  sales_amount: number;
}

export function getDateRangeFromPreset(preset: DateRangePreset): { startDate: string; endDate: string } {
  const today = new Date();
  const endDate = format(today, 'yyyy-MM-dd');
  let start: Date;

  switch (preset) {
    case '7D':
      start = subDays(today, 6);
      break;
    case '30D':
      start = subDays(today, 29);
      break;
    case 'MTD':
      start = startOfMonth(today);
      break;
    case 'YTD':
      start = startOfYear(today);
      break;
  }

  return { startDate: format(start, 'yyyy-MM-dd'), endDate };
}

export function isValidDateRange(startDate: string, endDate: string): boolean {
  return Boolean(startDate && endDate && startDate <= endDate);
}

export function useSalesPurchasesTrend(startDate: string, endDate: string) {
  return useQuery({
    queryKey: ['dashboard-analytics', 'sales-purchases-trend', startDate, endDate],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_dashboard_sales_purchases_trend', {
        p_start_date: startDate,
        p_end_date: endDate,
      });
      if (error) throw error;
      return (data ?? []) as SalesPurchasesTrendRow[];
    },
    enabled: isValidDateRange(startDate, endDate),
    staleTime: ANALYTICS_STALE_TIME,
  });
}

export function useCashFlowTrend(startDate: string, endDate: string) {
  return useQuery({
    queryKey: ['dashboard-analytics', 'cash-flow-trend', startDate, endDate],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_dashboard_cash_flow_trend', {
        p_start_date: startDate,
        p_end_date: endDate,
      });
      if (error) throw error;
      return (data ?? []) as CashFlowTrendRow[];
    },
    enabled: isValidDateRange(startDate, endDate),
    staleTime: ANALYTICS_STALE_TIME,
  });
}

export function useStockByFuel() {
  return useQuery({
    queryKey: ['dashboard-analytics', 'stock-by-fuel'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_dashboard_stock_by_fuel');
      if (error) throw error;
      return (data ?? []) as StockByFuelRow[];
    },
    staleTime: ANALYTICS_STALE_TIME,
  });
}

export function useReceivablesPayables() {
  return useQuery({
    queryKey: ['dashboard-analytics', 'receivables-payables'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_dashboard_receivables_payables');
      if (error) throw error;
      const rows = (data ?? []) as ReceivablesPayablesRow[];
      return rows[0] ?? { receivables: 0, payables: 0, net_position: 0 };
    },
    staleTime: ANALYTICS_STALE_TIME,
  });
}

export function useTopCustomers(limit = 5) {
  return useQuery({
    queryKey: ['dashboard-analytics', 'top-customers', limit],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_dashboard_top_customers', { p_limit: limit });
      if (error) throw error;
      return (data ?? []) as TopCustomerRow[];
    },
    staleTime: ANALYTICS_STALE_TIME,
  });
}

export function useTopSuppliers(limit = 5) {
  return useQuery({
    queryKey: ['dashboard-analytics', 'top-suppliers', limit],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_dashboard_top_suppliers', { p_limit: limit });
      if (error) throw error;
      return (data ?? []) as TopSupplierRow[];
    },
    staleTime: ANALYTICS_STALE_TIME,
  });
}

export function useProfitTrend(startDate: string, endDate: string) {
  return useQuery({
    queryKey: ['dashboard-analytics', 'profit-trend', startDate, endDate],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_dashboard_profit_trend', {
        p_start_date: startDate,
        p_end_date: endDate,
      });
      if (error) throw error;
      return (data ?? []) as ProfitTrendRow[];
    },
    enabled: isValidDateRange(startDate, endDate),
    staleTime: ANALYTICS_STALE_TIME,
  });
}

export function useFuelQuantitySold(startDate: string, endDate: string) {
  return useQuery({
    queryKey: ['dashboard-analytics', 'fuel-quantity-sold', startDate, endDate],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_dashboard_fuel_quantity_sold', {
        p_start_date: startDate,
        p_end_date: endDate,
      });
      if (error) throw error;
      return (data ?? []) as FuelQuantitySoldRow[];
    },
    enabled: isValidDateRange(startDate, endDate),
    staleTime: ANALYTICS_STALE_TIME,
  });
}
