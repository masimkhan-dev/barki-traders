import { useMemo, useState } from 'react';
import { format, parseISO } from 'date-fns';
import { BarChart3 } from 'lucide-react';
import { cn } from '@/lib/utils';
import {
  getDateRangeFromPreset,
  type DateRangePreset,
} from '@/lib/api/dashboard-analytics';
import { SalesPurchasesTrendChart } from '@/components/dashboard/charts/SalesPurchasesTrendChart';
import { CashFlowTrendChart } from '@/components/dashboard/charts/CashFlowTrendChart';
import { StockByFuelChart } from '@/components/dashboard/charts/StockByFuelChart';
import { ReceivablesPayablesSummary } from '@/components/dashboard/charts/ReceivablesPayablesSummary';
import { ProfitTrendChart } from '@/components/dashboard/charts/ProfitTrendChart';
import { FuelQuantitySoldChart } from '@/components/dashboard/charts/FuelQuantitySoldChart';
import { TopPartiesLists } from '@/components/dashboard/charts/TopPartiesLists';

const PRESETS: { id: DateRangePreset; label: string }[] = [
  { id: '7D', label: '7D' },
  { id: '30D', label: '30D' },
  { id: 'MTD', label: 'MTD' },
  { id: 'YTD', label: 'YTD' },
];

const PRESET_RANGE_LABELS: Record<DateRangePreset, string> = {
  '7D': 'Last 7 days',
  '30D': 'Last 30 days',
  MTD: 'Month to date',
  YTD: 'Year to date',
};

function formatAnalyticsRangeLabel(preset: DateRangePreset, startDate: string, endDate: string) {
  try {
    const start = format(parseISO(startDate), 'd MMM');
    const end = format(parseISO(endDate), 'd MMM yyyy');
    return `${PRESET_RANGE_LABELS[preset]} · ${start} – ${end}`;
  } catch {
    return `${PRESET_RANGE_LABELS[preset]} · ${startDate} – ${endDate}`;
  }
}

export function AnalyticsCharts() {
  const [preset, setPreset] = useState<DateRangePreset>('30D');

  const { startDate, endDate } = useMemo(() => getDateRangeFromPreset(preset), [preset]);

  return (
    <section className="space-y-4">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 pb-1">
        <div className="flex items-center gap-2">
          <BarChart3 className="h-4 w-4 text-[var(--color-primary)]" />
          <div>
            <h3 className="text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--color-text-muted)]">
              Analytics Overview
            </h3>
            <p className="text-[10px] font-medium text-[var(--color-text-muted)] tracking-wide mt-0.5">
              {formatAnalyticsRangeLabel(preset, startDate, endDate)}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-1 p-1 bg-[#FAFAFA] border border-[#F4F4F5] rounded-lg w-fit">
          {PRESETS.map(({ id, label }) => (
            <button
              key={id}
              type="button"
              onClick={() => setPreset(id)}
              className={cn(
                'px-3 py-1.5 text-[10px] font-black uppercase tracking-widest rounded-md transition-colors',
                preset === id
                  ? 'bg-[var(--color-primary)] text-white'
                  : 'text-[var(--color-text-muted)] hover:bg-white hover:text-slate-900'
              )}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <SalesPurchasesTrendChart startDate={startDate} endDate={endDate} />
        <CashFlowTrendChart startDate={startDate} endDate={endDate} />
        <ProfitTrendChart startDate={startDate} endDate={endDate} />
        <FuelQuantitySoldChart startDate={startDate} endDate={endDate} />
        <StockByFuelChart />
        <ReceivablesPayablesSummary />
        <TopPartiesLists />
      </div>
    </section>
  );
}
