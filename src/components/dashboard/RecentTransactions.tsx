
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatDate } from '@/lib/format';
import { Search, Filter, FileText, Printer, FileSpreadsheet } from 'lucide-react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

export function RecentTransactions() {
  const [searchTerm, setSearchTerm] = useState('');

  const { data: transactions, isLoading } = useQuery({
    queryKey: ['dashboard-feed'],
    queryFn: async () => {
      const { data, error } = await (supabase.rpc('get_dashboard_feed', { p_limit: 30 }) as any);
      if (error) throw error;
      return data;
    },
  });

  const filtered = transactions?.filter((t: any) =>
    t.party_name.toLowerCase().includes(searchTerm.toLowerCase()) ||
    t.description.toLowerCase().includes(searchTerm.toLowerCase()) ||
    t.voucher_no.toLowerCase().includes(searchTerm.toLowerCase())
  );

  if (isLoading) {
    return (
      <div className="bg-white rounded-3xl p-8 shadow-xl animate-pulse">
        <div className="h-8 bg-slate-100 w-1/4 mb-6 rounded-lg" />
        <div className="space-y-4">
          {[...Array(5)].map((_, i) => (
            <div key={i} className="h-12 bg-slate-50 rounded-xl" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="bg-white rounded-3xl shadow-xl border border-slate-100 overflow-hidden">
      {/* HEADER & FILTERS */}
      <div className="p-6 border-b border-slate-50 flex flex-col md:flex-row justify-between items-center gap-4 bg-slate-50/50">
        <div className="flex items-center gap-3">
          <div className="p-3 bg-blue-600 rounded-2xl">
            <FileText className="h-6 w-6 text-white" />
          </div>
          <div>
            <h3 className="text-xl font-black text-slate-800 tracking-tighter uppercase">Daily Activity Feed</h3>
            <p className="text-xs font-bold text-slate-500 uppercase tracking-widest">Party Wise Simplified Ledger</p>
          </div>
        </div>

        <div className="flex items-center gap-3 w-full md:w-auto">
          <div className="relative flex-1 md:w-64">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400" />
            <Input
              placeholder="Search Party or Ref..."
              className="pl-10 h-11 bg-white border-slate-200 rounded-xl font-semibold"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
            />
          </div>
          <Button variant="outline" size="icon" className="h-11 w-11 rounded-xl"><Filter className="h-4 w-4" /></Button>
          <div className="flex gap-1">
            <Button variant="outline" size="sm" onClick={() => window.print()} className="h-11 rounded-xl"><Printer className="h-4 w-4" /></Button>
            <Button variant="outline" size="sm" className="h-11 rounded-xl"><FileSpreadsheet className="h-4 w-4" /></Button>
          </div>
        </div>
      </div>

      {/* TRANSACTION TABLE */}
      <div className="overflow-x-auto">
        <table className="w-full text-left border-collapse">
          <thead>
            <tr className="bg-slate-800 text-white uppercase text-[10px] font-black tracking-[0.2em]">
              <th className="px-6 py-4">Date</th>
              <th className="px-6 py-4">Ref ID</th>
              <th className="px-6 py-4">Party / Account</th>
              <th className="px-6 py-4">Particulars</th>
              <th className="px-6 py-4 text-right">Paid (Debit)</th>
              <th className="px-6 py-4 text-right">Received (Credit)</th>
              <th className="px-6 py-4 text-right">Running Balance</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {filtered && filtered.length > 0 ? (
              filtered.map((txn: any) => (
                <tr key={txn.id} className="hover:bg-blue-50/30 transition-colors group">
                  <td className="px-6 py-4 text-xs font-bold text-slate-500 whitespace-nowrap">{formatDate(txn.date)}</td>
                  <td className="px-6 py-4 font-mono text-[10px] text-slate-400 group-hover:text-blue-600 transition-colors">{txn.voucher_no}</td>
                  <td className="px-6 py-4">
                    <span className="text-sm font-black text-slate-800 truncate block max-w-[200px]">{txn.party_name}</span>
                  </td>
                  <td className="px-6 py-4">
                    <span className="text-xs font-semibold text-slate-500 italic block truncate max-w-[250px]">{txn.description}</span>
                  </td>
                  <td className="px-6 py-4 text-right">
                    {txn.paid > 0 ? (
                      <span className="text-sm font-black text-rose-600 tabular-nums">{formatPKR(txn.paid)}</span>
                    ) : (
                      <span className="text-slate-200">-</span>
                    )}
                  </td>
                  <td className="px-6 py-4 text-right">
                    {txn.received > 0 ? (
                      <span className="text-sm font-black text-emerald-600 tabular-nums">{formatPKR(txn.received)}</span>
                    ) : (
                      <span className="text-slate-200">-</span>
                    )}
                  </td>
                  <td className="px-6 py-4 text-right bg-slate-50/50 group-hover:bg-blue-50 transition-colors">
                    <div className="flex flex-col items-end">
                      <span className={cn("text-sm font-black tabular-nums", txn.running_balance < 0 ? "text-rose-700" : "text-blue-700")}>
                        {formatPKR(Math.abs(txn.running_balance))}
                      </span>
                      <span className="text-[9px] font-black uppercase opacity-40">
                        {txn.running_balance >= 0 ? 'Debit' : 'Credit'}
                      </span>
                    </div>
                  </td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={7} className="px-6 py-20 text-center">
                  <div className="flex flex-col items-center gap-3">
                    <div className="p-4 bg-slate-50 rounded-full">
                      <Search className="h-8 w-8 text-slate-200" />
                    </div>
                    <p className="text-sm font-bold text-slate-400 uppercase tracking-widest">No matching activities found</p>
                  </div>
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {/* FOOTER */}
      <div className="p-4 bg-slate-50 border-t border-slate-100 flex justify-between items-center text-[10px] font-black text-slate-400 uppercase tracking-widest">
        <span>Showing Latest {filtered?.length || 0} Transactions</span>
        <span className="text-blue-600 cursor-pointer hover:underline">View All Activities →</span>
      </div>
    </div>
  );
}
