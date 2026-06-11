import { Loader2, AlertCircle, BarChart3 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

interface ChartCardProps {
  title: string;
  subtitle?: string;
  className?: string;
  isLoading?: boolean;
  isError?: boolean;
  errorMessage?: string;
  isEmpty?: boolean;
  emptyMessage?: string;
  onRetry?: () => void;
  children: React.ReactNode;
}

export function ChartCard({
  title,
  subtitle,
  className,
  isLoading,
  isError,
  errorMessage,
  isEmpty,
  emptyMessage = 'No data for selected period',
  onRetry,
  children,
}: ChartCardProps) {
  return (
    <div
      className={cn(
        'bg-white border border-[var(--color-card-border)] rounded-xl shadow-sm p-4 sm:p-5 flex flex-col min-h-[280px]',
        className
      )}
    >
      <div className="mb-4 pb-3 border-b border-[#F4F4F5]">
        <h4 className="text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--color-text-muted)]">
          {title}
        </h4>
        {subtitle && (
          <p className="text-[10px] font-medium text-[var(--color-text-muted)] mt-1 uppercase tracking-wider">
            {subtitle}
          </p>
        )}
      </div>

      {isLoading ? (
        <div className="flex-1 flex flex-col items-center justify-center gap-3 py-8">
          <Loader2 className="h-6 w-6 animate-spin text-slate-300" />
          <span className="text-[9px] font-black text-slate-400 uppercase tracking-[0.2em]">Loading analytics...</span>
        </div>
      ) : isError ? (
        <div className="flex-1 flex flex-col items-center justify-center gap-3 py-8 text-center px-4">
          <AlertCircle className="h-8 w-8 text-[var(--color-danger)]" />
          <p className="text-xs font-semibold text-[var(--color-danger-text)]">{errorMessage ?? 'Failed to load data'}</p>
          {onRetry && (
            <Button variant="outline" size="sm" className="text-[10px] font-black uppercase" onClick={onRetry}>
              Retry
            </Button>
          )}
        </div>
      ) : isEmpty ? (
        <div className="flex-1 flex flex-col items-center justify-center gap-3 py-8 opacity-50">
          <BarChart3 className="h-8 w-8 text-slate-300" />
          <p className="text-[10px] font-black uppercase tracking-widest text-slate-400">{emptyMessage}</p>
        </div>
      ) : (
        <div className="flex-1 min-h-0">{children}</div>
      )}
    </div>
  );
}
