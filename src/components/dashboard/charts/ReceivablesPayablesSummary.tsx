import { ChartCard } from './ChartCard';
import { useReceivablesPayables } from '@/lib/api/dashboard-analytics';
import { formatPKR } from '@/lib/format';
import { cn } from '@/lib/utils';

export function ReceivablesPayablesSummary() {
  const { data, isLoading, isError, error, refetch } = useReceivablesPayables();

  const receivables = data?.receivables ?? 0;
  const payables = data?.payables ?? 0;
  const netPosition = data?.net_position ?? 0;

  return (
    <ChartCard
      title="Receivables vs Payables"
      subtitle="Ledger-backed party balances"
      isLoading={isLoading}
      isError={isError}
      errorMessage={error?.message}
      onRetry={() => refetch()}
      isEmpty={false}
    >
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 h-full content-center">
        <div className="border border-[#F4F4F5] rounded-lg p-4 bg-[#FAFAFA]">
          <span className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--color-text-muted)]">
            Receivables (Lena)
          </span>
          <p className="text-xl font-bold text-[var(--color-success)] num-audit mt-2">{formatPKR(receivables)}</p>
        </div>
        <div className="border border-[#F4F4F5] rounded-lg p-4 bg-[#FAFAFA]">
          <span className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--color-text-muted)]">
            Payables (Dena)
          </span>
          <p className="text-xl font-bold text-[var(--color-danger)] num-audit mt-2">{formatPKR(payables)}</p>
        </div>
        <div className="border border-[#F4F4F5] rounded-lg p-4 bg-[#FAFAFA]">
          <span className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--color-text-muted)]">
            Net Position
          </span>
          <p
            className={cn(
              'text-xl font-bold num-audit mt-2',
              netPosition >= 0 ? 'text-[var(--color-success)]' : 'text-[var(--color-danger)]'
            )}
          >
            {formatPKR(Math.abs(netPosition))}
          </p>
          <span className="text-[9px] font-bold uppercase text-[var(--color-text-muted)]">
            {netPosition >= 0 ? 'Net Dr' : 'Net Cr'}
          </span>
        </div>
      </div>
    </ChartCard>
  );
}
