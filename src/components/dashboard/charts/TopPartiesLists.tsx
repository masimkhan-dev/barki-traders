import { ChartCard } from './ChartCard';
import { useTopCustomers, useTopSuppliers } from '@/lib/api/dashboard-analytics';
import { formatPKR } from '@/lib/format';

export function TopPartiesLists() {
  const customers = useTopCustomers(5);
  const suppliers = useTopSuppliers(5);

  const isLoading = customers.isLoading || suppliers.isLoading;
  const isError = customers.isError || suppliers.isError;
  const errorMessage = customers.error?.message ?? suppliers.error?.message;

  const handleRetry = () => {
    void customers.refetch();
    void suppliers.refetch();
  };

  const customerRows = customers.data ?? [];
  const supplierRows = suppliers.data ?? [];
  const isEmpty = !isLoading && !isError && customerRows.length === 0 && supplierRows.length === 0;

  return (
    <ChartCard
      title="Top Parties Outstanding"
      subtitle="Customers (lena) & suppliers (dena)"
      isLoading={isLoading}
      isError={isError}
      errorMessage={errorMessage}
      onRetry={handleRetry}
      isEmpty={isEmpty}
      emptyMessage="No outstanding party balances"
      className="lg:col-span-2"
    >
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div>
          <h5 className="text-[10px] font-black uppercase tracking-widest text-[var(--color-success)] mb-3">
            Top 5 Customers
          </h5>
          {customerRows.length === 0 ? (
            <p className="text-[10px] text-slate-400 font-semibold uppercase py-4">No receivables</p>
          ) : (
            <div className="space-y-2">
              {customerRows.map((row, idx) => (
                <div
                  key={row.party_id}
                  className="flex items-center justify-between py-2 border-b border-[#F4F4F5] last:border-0"
                >
                  <div className="flex items-center gap-2 min-w-0">
                    <span className="text-[10px] font-black text-slate-400 w-4">{idx + 1}</span>
                    <span className="text-xs font-bold text-slate-800 uppercase truncate">{row.party_name}</span>
                  </div>
                  <span className="text-xs font-bold text-[var(--color-success)] num-audit ml-2 shrink-0">
                    {formatPKR(row.outstanding_amount)}
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>

        <div>
          <h5 className="text-[10px] font-black uppercase tracking-widest text-[var(--color-danger)] mb-3">
            Top 5 Suppliers
          </h5>
          {supplierRows.length === 0 ? (
            <p className="text-[10px] text-slate-400 font-semibold uppercase py-4">No payables</p>
          ) : (
            <div className="space-y-2">
              {supplierRows.map((row, idx) => (
                <div
                  key={row.party_id}
                  className="flex items-center justify-between py-2 border-b border-[#F4F4F5] last:border-0"
                >
                  <div className="flex items-center gap-2 min-w-0">
                    <span className="text-[10px] font-black text-slate-400 w-4">{idx + 1}</span>
                    <span className="text-xs font-bold text-slate-800 uppercase truncate">{row.party_name}</span>
                  </div>
                  <span className="text-xs font-bold text-[var(--color-danger)] num-audit ml-2 shrink-0">
                    {formatPKR(row.payable_amount)}
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </ChartCard>
  );
}
