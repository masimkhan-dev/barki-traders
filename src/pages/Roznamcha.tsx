// VERIFICATION: Roznamcha.tsx updated at 2026-02-05 12:40
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatDate } from '@/lib/format';
import {
  Loader2,
  CalendarDays,
  ShoppingCart,
  Truck,
  Receipt,
  Wallet,
  Banknote,
  RotateCcw,
  CheckCircle2,
  CheckCircle,
  ShieldCheck,
  ChevronLeft,
  ChevronRight,
  Edit2,
  Trash2,
  ShieldAlert
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { useToast } from '@/hooks/use-toast';
import { useQueryClient, useMutation } from '@tanstack/react-query';
import { ReversalModal } from '@/components/modals/ReversalModal';
import { cn } from '@/lib/utils';
import { Card } from '@/components/ui/card';

interface DailyTransaction {
  id: string;
  time: string;
  voucher_no: string;
  type: string;
  party_name: string;
  narration: string;
  debit: number;
  credit: number;
  reconciled: boolean;
  is_reversed: boolean;
  mode?: 'CASH/BANK' | 'CREDIT';
  nominal_value?: number;
  is_cash_tx?: boolean;
}

export default function Roznamcha() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { toast } = useToast();
  const [selectedDate, setSelectedDate] = useState(new Date().toISOString().split('T')[0]);
  const { role } = useAuth();
  const [revModalOpen, setRevModalOpen] = useState(false);
  const [selectedVoucher, setSelectedVoucher] = useState<string | null>(null);
  const [deleteConfirmOpen, setDeleteConfirmOpen] = useState(false);
  const [itemToDelete, setItemToDelete] = useState<DailyTransaction | null>(null);

  const deleteMutation = useMutation({
    mutationFn: async (t: DailyTransaction) => {
      let table: any = 'ledger_entries';
      if (t.type === 'sale') table = 'sales';
      else if (t.type === 'purchase') table = 'purchases';
      else if (t.type === 'receipt' || t.type === 'payment') {
        const { data: pay } = await supabase.from('payments').select('id').eq('voucher_no', t.voucher_no).maybeSingle();
        table = pay ? 'payments' : 'ledger_entries';
      }

      const { error } = await supabase.from(table).delete().eq('voucher_no', t.voucher_no);
      if (error) throw error;
      return true;
    },
    onSuccess: () => {
      toast({ title: 'Transaction Terminated', description: 'The entry has been successfully scrubbed and balanced reverted.' });
      queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
      queryClient.invalidateQueries({ queryKey: ['calculated-inventory'] });
      queryClient.invalidateQueries({ queryKey: ['all-accounts-fresh'] });
      queryClient.invalidateQueries({ queryKey: ['transaction-history'] });
      setDeleteConfirmOpen(false);
    },
    onError: (e: any) => toast({ variant: 'destructive', title: 'Deletion Blocked', description: e.message })
  });

  // Fetch ALL ledger entries for the selected date to show a complete diary
  const { data: transactions, isLoading } = useQuery({
    queryKey: ['roznamcha', selectedDate],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('ledger_entries')
        .select(`
          id,
          created_at,
          voucher_no,
          voucher_type,
          debit_amount,
          credit_amount,
          narration,
          reconciliation_status,
          is_reversed,
          accounts!inner(code, name),
          party:parties(name)
        `)
        .eq('posting_date', selectedDate)
        .order('created_at', { ascending: true })
        .order('voucher_no', { ascending: true });

      if (error) throw error;

      // Group by voucher_no to show one line per transaction
      const groupedMap = new Map<string, DailyTransaction & { raw_created_at: string }>();

      const entries = (data || []) as any[];

      entries.forEach((entry: any) => {
        const vNo = entry.voucher_no;
        const isCashOrBank = ['1010', '1020'].includes(entry.accounts?.code);

        if (!groupedMap.has(vNo)) {
          groupedMap.set(vNo, {
            id: entry.id,
            time: new Date(entry.created_at).toLocaleTimeString('en-PK', { hour: '2-digit', minute: '2-digit' }),
            raw_created_at: entry.created_at,
            voucher_no: vNo,
            type: entry.voucher_type,
            party_name: entry.party?.name || entry.accounts?.name || 'General',
            narration: (entry.narration || '').replace(/^Ref: N\/A - /, '').trim(),
            debit: isCashOrBank ? (Number(entry.debit_amount) || 0) : 0,
            credit: isCashOrBank ? (Number(entry.credit_amount) || 0) : 0,
            reconciled: entry.reconciliation_status || false,
            is_reversed: entry.is_reversed || false,
            is_cash_tx: isCashOrBank || false
          });
        } else {
          const existing = groupedMap.get(vNo)!;
          if (isCashOrBank) {
            existing.debit += (Number(entry.debit_amount) || 0);
            existing.credit += (Number(entry.credit_amount) || 0);
            existing.is_cash_tx = true;
          }
          if (entry.party?.name) {
            existing.party_name = entry.party.name;
          }
        }
      });

      // Secondary pass to handle visual 'Balance' for Credit entries without affecting Cash Book totals
      const finalTransactions = Array.from(groupedMap.values()).map(t => {
        if (t.debit === 0 && t.credit === 0) {
          const originalEntries = entries.filter(e => e.voucher_no === t.voucher_no);
          const nominalAmount = originalEntries.length > 0
            ? Math.max(...originalEntries.map(e => Math.max(Number(e.debit_amount) || 0, Number(e.credit_amount) || 0)))
            : 0;

          return {
            ...t,
            nominal_value: nominalAmount,
            mode: 'CREDIT' as const
          };
        }
        return {
          ...t,
          nominal_value: 0,
          mode: 'CASH/BANK' as const
        };
      });

      // Final Strict Sort: Entry Time then Voucher Number
      return finalTransactions.sort((a, b) => {
        const timeDiff = new Date(a.raw_created_at).getTime() - new Date(b.raw_created_at).getTime();
        if (timeDiff !== 0) return timeDiff;
        return a.voucher_no.localeCompare(b.voucher_no);
      });
    },
  });

  // Calculate totals EXCLUDING reversed entries and reversal entries
  const totals = transactions?.reduce(
    (acc, t) => {
      // Skip if this entry is reversed OR if it's a reversal entry (REV-)
      const isReversalEntry = t.voucher_no.startsWith('REV-');
      if (t.is_reversed || isReversalEntry) {
        return acc;
      }

      let dr = t.debit || 0;
      let cr = t.credit || 0;

      // Include nominal value for Credit transactions so totals match the visible table columns
      if (t.mode === 'CREDIT' && t.nominal_value) {
        if (t.type === 'sale' || t.type === 'receipt') dr = t.nominal_value;
        if (t.type === 'purchase' || t.type === 'payment') cr = t.nominal_value;
      }

      return {
        debit: acc.debit + dr,
        credit: acc.credit + cr,
      };
    },
    { debit: 0, credit: 0 }
  ) || { debit: 0, credit: 0 };

  const reconcileMutation = useMutation({
    mutationFn: async (voucherNo: string) => {
      const { error } = await (supabase as any).rpc('mark_as_reconciled', { p_voucher_no: voucherNo });
      if (error) throw error;
      return true;
    },
    onSuccess: () => {
      toast({ title: 'Reconciled', description: 'Transaction marked as verified.' });
      queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
    },
    onError: (e) => toast({ variant: 'destructive', title: 'Error', description: e.message })
  });

  const dailyNetChange = totals.debit - totals.credit;

  const getTypeIcon = (type: string) => {
    switch (type) {
      case 'sale': return <ShoppingCart className="h-4 w-4 text-success" />;
      case 'purchase': return <Truck className="h-4 w-4 text-primary" />;
      case 'receipt': return <Receipt className="h-4 w-4 text-success" />;
      case 'payment': return <Wallet className="h-4 w-4 text-destructive" />;
      default: return null;
    }
  };

  const getTypeLabel = (type: string) => {
    switch (type) {
      case 'sale': return 'Sale';
      case 'purchase': return 'Purchase';
      case 'receipt': return 'Receipt';
      case 'payment': return 'Payment';
      case 'munshi_voucher': return 'Transaction';
      case 'manage_transaction': return 'Transfer';
      default: return type.replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase());
    }
  };

  return (

    <DashboardLayout>
      <div className="max-w-7xl mx-auto pb-20 print:p-0">

        {/* STICKY FILTER BAR */}
        <div className="sticky-filter-bar print:hidden px-4">
          <div className="max-w-7xl mx-auto flex flex-wrap items-center justify-between gap-4">
            <div className="report-header mb-0">
              <h1 className="report-title">Naveed Musazai</h1>
              <p className="report-subtitle">Daily Cash & Bank Book — Roznamcha</p>
            </div>

            <div className="flex flex-wrap items-center gap-3 bg-slate-50 p-2 border border-slate-200 rounded-sm">
              <Button
                variant="outline"
                size="icon"
                onClick={() => {
                  const d = new Date(selectedDate);
                  d.setDate(d.getDate() - 1);
                  setSelectedDate(d.toISOString().split('T')[0]);
                }}
                className="h-8 w-8 rounded-none border-slate-300"
              >
                <ChevronLeft className="h-4 w-4 text-slate-600" />
              </Button>

              <div className="flex flex-col">
                <label className="text-[9px] font-bold uppercase text-slate-500 mb-1">Journal Date</label>
                <input
                  type="date"
                  value={selectedDate}
                  onChange={(e) => setSelectedDate(e.target.value)}
                  className="h-8 px-2 border border-slate-300 rounded-none font-bold text-xs"
                />
              </div>

              <Button
                variant="outline"
                size="icon"
                onClick={() => {
                  const d = new Date(selectedDate);
                  d.setDate(d.getDate() + 1);
                  setSelectedDate(d.toISOString().split('T')[0]);
                }}
                className="h-8 w-8 rounded-none border-slate-300"
              >
                <ChevronRight className="h-4 w-4 text-slate-600" />
              </Button>

              <div className="w-px h-6 bg-slate-200 mx-1"></div>

              <Button
                variant="secondary"
                size="sm"
                onClick={() => setSelectedDate(new Date().toISOString().split('T')[0])}
                className="h-8 px-3 text-[10px] font-bold bg-slate-200 text-slate-700 hover:bg-slate-300 rounded-none uppercase tracking-wide"
              >
                Today
              </Button>
            </div>
          </div>
        </div>

        <div className="px-4 space-y-8">
          {/* Cash Balance Summary */}
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div className="summary-card">
              <span className="summary-label text-assets font-black">Total Inward (Received/Sales)</span>
              <span className="summary-value text-assets">{formatPKR(totals.debit)}</span>
            </div>
            <div className="summary-card">
              <span className="summary-label text-liabilities font-black">Total Outward (Paid/Purchases)</span>
              <span className="summary-value text-liabilities">{formatPKR(totals.credit)}</span>
            </div>
            <div className={cn(
              "summary-card border-l-4",
              dailyNetChange >= 0 ? "border-l-emerald-500 bg-emerald-50/20 text-assets" : "border-l-rose-500 bg-rose-50/20 text-liabilities"
            )}>
              <span className="summary-label font-black">Daily Net Variance</span>
              <span className="summary-value num-audit">
                {dailyNetChange === 0 ? "0.00" : formatPKR(Math.abs(dailyNetChange))}
                {dailyNetChange !== 0 && (
                  <span className="text-[10px] ml-1 uppercase">{dailyNetChange >= 0 ? 'Dr' : 'Cr'}</span>
                )}
              </span>
            </div>
          </div>

          {/* Transactions Table */}
          <div>
            {isLoading ? (
              <div className="flex flex-col items-center justify-center py-24 gap-4">
                <Loader2 className="h-10 w-10 animate-spin text-slate-300" />
                <span className="text-[10px] font-black text-slate-400 uppercase tracking-[0.2em]">Synchronizing Daily Ledger...</span>
              </div>
            ) : transactions && transactions.length > 0 ? (
              <div className="border border-slate-300">
                {/* Desktop View: Table */}
                <div className="hidden md:block overflow-x-auto">
                  <table className="ledger-table">
                    <thead>
                      <tr className="bg-slate-900">
                        <th className="w-20 !text-white">Time</th>
                        <th className="w-28 !text-white">Voucher No</th>
                        <th className="w-48 !text-white">Type & Mode</th>
                        <th className="!text-white">Particulars / Journal Description</th>
                        <th className="right-align w-32 !text-white">Inward (+) <br /><span className="text-[9px] font-normal tracking-normal text-slate-300">Received/Sales</span></th>
                        <th className="right-align w-32 !text-white">Outward (-) <br /><span className="text-[9px] font-normal tracking-normal text-slate-300">Paid/Purchases</span></th>
                        <th className="center-align w-16 !text-white">Verif</th>
                        <th className="center-align w-24 !text-white print:hidden">Audit Access</th>
                      </tr>
                    </thead>
                    <tbody>
                      {transactions.map((t) => {
                        const rowColor =
                          t.type === 'sale' || t.type === 'receipt' ? "bg-emerald-50/40 hover:bg-emerald-100/60" :
                            t.type === 'purchase' ? "bg-sky-50/40 hover:bg-sky-100/60" :
                              t.type === 'payment' ? "bg-rose-50/40 hover:bg-rose-100/60" :
                                "bg-slate-50/40 hover:bg-slate-100/60";

                        return (
                          <tr key={t.id} className={cn("transition-colors", rowColor)}>
                            <td className="num-audit text-xs">{t.time}</td>
                            <td className="num-audit text-xs !font-medium text-slate-500 group/rev">
                              <div className="flex items-center justify-between">
                                <span>{t.voucher_no}</span>
                                <button
                                  onClick={() => { setSelectedVoucher(t.voucher_no); setRevModalOpen(true); }}
                                  className="opacity-0 group-hover/rev:opacity-100 p-1 hover:text-rose-600 transition-all print:hidden"
                                  title="Reverse Transaction"
                                >
                                  <RotateCcw className="h-4 w-4" />
                                </button>
                              </div>
                            </td>
                            <td>
                              <div className="flex flex-col gap-1">
                                <span className="font-bold uppercase text-xs flex items-center gap-1">
                                  {getTypeIcon(t.type)} {getTypeLabel(t.type)}
                                </span>
                                <span className={cn(
                                  "text-[10px] font-black px-1.5 py-0.5 w-fit border rounded-sm",
                                  t.mode === 'CASH/BANK' ? "bg-emerald-600 text-white border-emerald-700" : "bg-slate-200 text-slate-600 border-slate-300"
                                )}>
                                  {t.mode}
                                </span>
                              </div>
                            </td>
                            <td>
                              <div className="flex flex-col">
                                <span className="font-bold text-slate-900 uppercase text-xs tracking-tight">{t.party_name}</span>
                                <span className="text-[11px] italic text-slate-500 font-medium">
                                  {(t.narration || '').replace(/^Ref: N\/A - /, "").replace(/^Ref: N\/A/, "").trim() || 'SYSTEM ENTRY'}
                                </span>
                              </div>
                            </td>
                            <td className="right-align num-audit font-bold text-sm">
                              {t.debit > 0 ? (
                                <span className="text-emerald-700">{formatPKR(t.debit).replace('Rs. ', '')}</span>
                              ) : (t.mode === 'CREDIT' && (t.type === 'sale' || t.type === 'receipt' || t.type === 'transfer')) ? (
                                <span className="text-slate-400 italic font-normal">{formatPKR(t.nominal_value || 0).replace('Rs. ', '')}</span>
                              ) : '-'}
                            </td>
                            <td className="right-align num-audit font-bold text-sm">
                              {t.credit > 0 ? (
                                <span className="text-rose-700">{formatPKR(t.credit).replace('Rs. ', '')}</span>
                              ) : (t.mode === 'CREDIT' && (t.type === 'purchase' || t.type === 'payment')) ? (
                                <span className="text-slate-400 italic font-normal">{formatPKR(t.nominal_value || 0).replace('Rs. ', '')}</span>
                              ) : '-'}
                            </td>
                            <td className="center-align print:hidden">
                              <button
                                onClick={() => !t.reconciled && reconcileMutation.mutate(t.voucher_no)}
                                disabled={t.reconciled || reconcileMutation.isPending}
                                className={cn(
                                  "p-1.5 rounded-full transition-all",
                                  t.reconciled ? "text-emerald-600" : "text-slate-300 hover:text-emerald-400"
                                )}
                              >
                                {t.reconciled ? <ShieldCheck className="h-4 w-4" /> : <CheckCircle className="h-4 w-4" />}
                              </button>
                            </td>
                            <td className="center-align print:hidden">
                              <div className="flex items-center justify-center gap-1">
                                <Button
                                  variant="ghost"
                                  size="icon"
                                  className="h-7 w-7 text-slate-400 hover:text-slate-900"
                                  onClick={() => {
                                    if (t.type === 'sale' || t.type === 'purchase' || t.type === 'transfer') {
                                      navigate(`/manage-transactions?edit=${t.voucher_no}`);
                                    } else if (t.type === 'receipt' || t.type === 'payment') {
                                      navigate(`/expenses?edit=${t.voucher_no}`);
                                    } else {
                                      toast({ title: 'System Notice', description: 'Journal entries must be reversed for security.' });
                                    }
                                  }}
                                >
                                  <Edit2 className="h-3.5 w-3.5" />
                                </Button>
                                {(role === 'admin' || role === 'accountant') && (
                                  <Button
                                    variant="ghost"
                                    size="icon"
                                    className="h-7 w-7 text-slate-300 hover:text-rose-600"
                                    onClick={() => { setItemToDelete(t); setDeleteConfirmOpen(true); }}
                                  >
                                    <Trash2 className="h-3.5 w-3.5" />
                                  </Button>
                                )}
                              </div>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                    <tfoot className="bg-slate-50 font-black border-t-2 border-slate-900">
                      <tr>
                        <td colSpan={4} className="px-4 py-3 right-align uppercase text-xs">Closing Totals for {selectedDate}:</td>
                        <td className="px-4 py-3 right-align text-xl text-emerald-700 num-audit underline decoration-double">{formatPKR(totals.debit)}</td>
                        <td className="px-4 py-3 right-align text-xl text-rose-700 num-audit underline decoration-double">{formatPKR(totals.credit)}</td>
                        <td></td>
                      </tr>
                    </tfoot>
                  </table>
                </div>

                {/* Mobile View: Cards */}
                <div className="md:hidden divide-y divide-slate-200">
                  {transactions.map((t) => {
                    const cardColor =
                      t.type === 'sale' || t.type === 'receipt' ? "bg-emerald-50/50" :
                        t.type === 'purchase' ? "bg-sky-50/50" :
                          t.type === 'payment' ? "bg-rose-50/50" :
                            "bg-slate-50/50";

                    return (
                      <div key={t.id} className={cn("p-4 space-y-2", cardColor)}>
                        <div className="flex justify-between items-start">
                          <span className="num-audit text-[10px] text-slate-400">{t.time} • {t.voucher_no}</span>
                          <span className="font-black text-[9px] uppercase px-2 py-0.5 bg-white/60 border border-black/5 rounded-sm">
                            {getTypeLabel(t.type)}
                          </span>
                        </div>
                        <p className="text-xs font-bold text-slate-900 uppercase">
                          {t.party_name} - <span className="font-medium text-[10px] lowercase italic text-slate-500">{t.narration}</span>
                        </p>
                        <div className="flex justify-between items-center pt-2">
                          <div className="flex gap-4">
                            {t.debit > 0 && <span className="num-audit font-black text-emerald-700">{formatPKR(t.debit)} <span className="text-[8px] text-slate-400 uppercase">In</span></span>}
                            {t.credit > 0 && <span className="num-audit font-black text-rose-700">{formatPKR(t.credit)} <span className="text-[8px] text-slate-400 uppercase">Out</span></span>}
                          </div>
                          <div className="flex gap-1.5">
                            <button onClick={() => { setSelectedVoucher(t.voucher_no); setRevModalOpen(true); }} className="p-1.5 text-slate-300"><RotateCcw className="h-4 w-4" /></button>
                            <button onClick={() => !t.reconciled && reconcileMutation.mutate(t.voucher_no)} className={cn("p-1.5", t.reconciled ? "text-emerald-600" : "text-slate-200")}><ShieldCheck className="h-4 w-4" /></button>
                          </div>
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            ) : (
              <div className="center-align py-32 border border-dashed border-slate-300 opacity-50 italic">
                No ledger entries found for the selected date.
              </div>
            )}
          </div>

        </div>
      </div>

      <ReversalModal
        isOpen={revModalOpen}
        voucherNo={selectedVoucher}
        onClose={() => setRevModalOpen(false)}
      />

      <AlertDialog open={deleteConfirmOpen} onOpenChange={setDeleteConfirmOpen}>
        <AlertDialogContent className="bg-white border-2 border-rose-600 shadow-2xl rounded-none">
          <AlertDialogHeader>
            <div className="flex items-center gap-3 text-rose-600 mb-2">
              <ShieldAlert className="h-8 w-8" />
              <AlertDialogTitle className="text-xl font-black uppercase tracking-tighter">System Scrub Approval</AlertDialogTitle>
            </div>
            <AlertDialogDescription className="text-slate-900 font-bold uppercase text-[11px] leading-relaxed">
              VOUCHER: <span className="text-rose-600 font-black">{itemToDelete?.voucher_no}</span><br />
              TYPE: {itemToDelete?.type} | PARTY: {itemToDelete?.party_name}<br /><br />
              WARNING: Deleting this record is a high-level audit event. The system will automatically revert inventory and party balances. This action is ARCHIVED for owner review.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter className="mt-6 border-t pt-4">
            <AlertDialogCancel className="rounded-none border-slate-900 font-black text-[10px] uppercase">Abort</AlertDialogCancel>
            <AlertDialogAction
              className="rounded-none bg-rose-600 hover:bg-rose-700 text-white font-black text-[10px] uppercase px-8"
              onClick={(e) => {
                e.preventDefault();
                if (itemToDelete) deleteMutation.mutate(itemToDelete);
              }}
              disabled={deleteMutation.isPending}
            >
              {deleteMutation.isPending ? "SCRUBBING..." : "CONFIRM DELETION"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </DashboardLayout>

  );
}
