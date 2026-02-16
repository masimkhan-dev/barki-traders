import { useState, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { ReversalModal } from '@/components/modals/ReversalModal';
import { formatPKR, formatNumber } from '@/lib/format';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Card } from '@/components/ui/card';
import {
  Printer,
  FileSpreadsheet,
  FileMinus,
  Search,
  Download,
  ShieldCheck,
  RotateCcw,
  Loader2
} from 'lucide-react';
import { toast } from 'sonner';
import { cn } from '@/lib/utils';

// Helper: CSV Export
const exportToCSV = (data: any[], filename: string) => {
  if (!data || data.length === 0) return;
  const headers = Object.keys(data[0]).join(',');
  const rows = data.map(row =>
    Object.values(row).map(val =>
      typeof val === 'string' ? `"${val.replace(/"/g, '""')}"` : val
    ).join(',')
  );
  const csvContent = [headers, ...rows].join('\n');
  const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
  const link = document.createElement('a');
  link.href = URL.createObjectURL(blob);
  link.download = `${filename}_${new Date().toISOString().split('T')[0]}.csv`;
  link.click();
};

// Helper: Classic Date Format (DD-MM-YY)
const formatClassicDate = (dateStr: string | null | undefined): string => {
  if (!dateStr) return '-';
  const d = new Date(dateStr);
  const day = String(d.getDate()).padStart(2, '0');
  const month = String(d.getMonth() + 1).padStart(2, '0');
  const year = String(d.getFullYear()).slice(-2);
  return `${day}-${month}-${year}`;
};

// Helper: Validate UUID
const isValidUUID = (str: string | null | undefined): boolean => {
  if (!str || typeof str !== 'string') return false;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(str.trim());
};

export default function AccountStatement() {
  const today = new Date();
  const firstDayOfMonth = new Date(today.getFullYear(), today.getMonth(), 1);

  const [selectedParty, setSelectedParty] = useState<string>('');
  const [startDate, setStartDate] = useState<string>(firstDayOfMonth.toISOString().split('T')[0]);
  const [endDate, setEndDate] = useState<string>(today.toISOString().split('T')[0]);

  // Use null to represent "no party selected"
  const [appliedParty, setAppliedParty] = useState<string | null>(null);
  const [appliedStart, setAppliedStart] = useState<string>(startDate);
  const [appliedEnd, setAppliedEnd] = useState<string>(endDate);

  const [revModalOpen, setRevModalOpen] = useState(false);
  const [selectedVoucher, setSelectedVoucher] = useState<string | null>(null);

  const { data: parties } = useQuery({
    queryKey: ['parties-list'],
    queryFn: async () => {
      const { data, error } = await supabase.from('parties').select('id, name').order('name');
      if (error) {
        toast.error("Failed to load parties");
        throw error;
      }
      return data;
    },
  });

  const activeParty = parties?.find((p) => p.id === appliedParty);

  const handleSearch = () => {
    if (!selectedParty || !isValidUUID(selectedParty)) {
      toast.error("Please select a valid account khata");
      return;
    }
    setAppliedParty(selectedParty);
    setAppliedStart(startDate);
    setAppliedEnd(endDate);
  };

  const { data: rawStatement, isLoading } = useQuery({
    queryKey: ['party-statement-v8', appliedParty, appliedStart, appliedEnd],
    enabled: appliedParty !== null && isValidUUID(appliedParty) && !!appliedStart && !!appliedEnd,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_party_statement', {
        p_party_id: appliedParty!,
        p_start_date: appliedStart,
        p_end_date: appliedEnd,
      });

      if (error) {
        console.error("RPC get_party_statement failed:", error);
        toast.error(`Failed to load statement: ${error.message || 'Unknown error'}`);
        throw new Error(error.message || 'RPC call failed');
      }

      return data as any as Array<{
        posting_date: string;
        voucher_no: string;
        particulars: string;
        debit: number;
        credit: number;
        running_balance: number;
        fuel_name: string;
        qty?: number;
        quantity?: number;
        rate?: number;
        is_reversed_entry: boolean;
      }>;
    },
  });

  const { data: productSummary } = useQuery({
    queryKey: ['party-product-summary-v8', appliedParty, appliedStart, appliedEnd],
    enabled: appliedParty !== null && isValidUUID(appliedParty) && !!appliedStart && !!appliedEnd,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_party_product_summary', {
        p_party_id: appliedParty!,
        p_start_date: appliedStart,
        p_end_date: appliedEnd,
      });

      if (error) {
        console.warn("Product summary failed:", error);
        return [];
      }

      return data as Array<{ fuel_name: string; total_qty: number }>;
    },
  });

  const stats = useMemo(() => {
    if (!rawStatement || rawStatement.length === 0) return { opening: 0, balance: 0, totalDebit: 0, totalCredit: 0 };
    const openingRow = rawStatement[0].voucher_no === 'OPEN' ? rawStatement[0] : null;
    const opening = openingRow ? openingRow.running_balance : 0;

    // Calculate totals excluding the opening row and reversed entries
    const transactions = rawStatement.filter(r => r.voucher_no !== 'OPEN' && !r.is_reversed_entry);
    const totalDebit = transactions.reduce((sum, r) => sum + (Number(r.debit) || 0), 0);
    const totalCredit = transactions.reduce((sum, r) => sum + (Number(r.credit) || 0), 0);

    const closing = rawStatement[rawStatement.length - 1];
    return {
      opening,
      totalDebit,
      totalCredit,
      balance: closing.running_balance
    };
  }, [rawStatement]);

  return (
    <DashboardLayout>
      <div className="bg-white min-h-screen pb-20 print:p-0">
        <style dangerouslySetInnerHTML={{
          __html: `
          @import url('https://fonts.googleapis.com/css2?family=Montserrat:wght@700;900&display=swap');
          
          @media screen { .print-only { display: none !important; } }
          @media print {
            @page { size: A4 portrait; margin: 8mm; }
            body * { visibility: hidden !important; }
            .print-container-base, .print-container-base * { visibility: visible !important; }
            .print-container-base { 
              position: absolute !important; 
              left: 0 !important; 
              top: 0 !important; 
              width: 100% !important; 
              border: none !important; 
              padding: 0 !important; 
              margin: 0 !important; 
              background: white !important;
            }
            .print-header {
              font-family: 'Montserrat', sans-serif !important;
              text-align: center;
              margin-bottom: 20px;
              border-bottom: 2pt solid #000;
              padding-bottom: 10px;
            }
            .print-summary-box {
              display: grid !important;
              grid-template-columns: repeat(4, 1fr) !important;
              gap: 0 !important;
              border: 1.5pt solid black !important;
              margin-bottom: 15px !important;
              font-family: 'Montserrat', sans-serif !important;
            }
            .print-summary-item {
              border-right: 1pt solid black !important;
              padding: 8px 5px !important;
              text-align: center;
              display: flex !important;
              flex-direction: column !important;
              justify-content: center;
            }
            .print-summary-item:last-child { border-right: none !important; background: #000 !important; color: #fff !important; -webkit-print-color-adjust: exact; }
            .print-summary-label {
              font-size: 7pt !important;
              text-transform: uppercase !important;
              font-weight: 900 !important;
              margin-bottom: 2px;
            }
            .print-summary-value {
              font-size: 11pt !important;
              font-weight: 900 !important;
              font-family: 'JetBrains Mono', monospace !important;
            }
            .print-table { 
              width: 100% !important; 
              border-collapse: collapse !important; 
              border: 1.2pt solid black !important; 
              font-family: 'JetBrains Mono', monospace !important;
            }
            .print-table th { 
              background-color: #f1f5f9 !important; 
              color: black !important; 
              border: 1pt solid black !important; 
              padding: 6px 4px !important; 
              font-size: 8pt !important; 
              font-weight: bold !important; 
              text-transform: uppercase !important;
              font-family: 'Montserrat', sans-serif !important;
            }
            .print-table td { 
              border: 0.5pt solid #ccc !important; 
              padding: 5px 4px !important; 
              font-size: 7.5pt !important; 
              color: black !important; 
            }
            .print-neg-balance { color: #15803d !important; font-weight: bold !important; }
            .print-pos-balance { color: #be123c !important; font-weight: bold !important; }
            .print\:hidden, button, nav, aside, .react-datepicker { display: none !important; }
          }
        `}} />

        {/* STICKY FILTER BAR (Strict Accounting Layout) */}
        <div className="sticky-filter-bar print:hidden px-4">
          <div className="max-w-7xl mx-auto flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6">
            <div className="report-header mb-0">
              <h1 className="report-title">Account Register</h1>
              <p className="report-subtitle text-[10px]">Professional Audit Terminal v8.0</p>
            </div>

            <div className="flex flex-wrap items-center gap-3 bg-slate-50 p-2 border border-slate-200">
              <div className="min-w-[220px] flex flex-col">
                <label className="text-[9px] font-black uppercase text-slate-500 mb-1">Account Khata</label>
                <Select value={selectedParty} onValueChange={setSelectedParty}>
                  <SelectTrigger className="h-9 bg-white font-bold border-slate-300 rounded-none focus:ring-0">
                    <SelectValue placeholder="Search..." />
                  </SelectTrigger>
                  <SelectContent className="rounded-none border-slate-900">
                    {parties?.map(p => (
                      <SelectItem key={p.id} value={p.id} className="font-bold text-xs uppercase">
                        {p.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="flex flex-col">
                <label className="text-[9px] font-black uppercase text-slate-500 mb-1">From</label>
                <input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} className="h-9 px-3 border border-slate-300 rounded-none font-bold text-xs outline-none focus:border-slate-900" />
              </div>
              <div className="flex flex-col">
                <label className="text-[9px] font-black uppercase text-slate-500 mb-1">To</label>
                <input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} className="h-9 px-3 border border-slate-300 rounded-none font-bold text-xs outline-none focus:border-slate-900" />
              </div>
              <div className="flex gap-2 self-end mb-0.5">
                <Button onClick={handleSearch} className="h-9 bg-slate-900 hover:bg-black text-white px-6 font-black uppercase text-[10px] tracking-widest rounded-none">
                  Query
                </Button>
                <Button variant="outline" size="icon" className="h-9 w-9 rounded-none border-slate-300 bg-white" onClick={() => window.print()}>
                  <Printer className="h-4 w-4" />
                </Button>
                <Button variant="outline" size="icon" className="h-9 w-9 rounded-none border-slate-300 bg-white text-green-700" onClick={() => exportToCSV(rawStatement || [], 'account_statement')}>
                  <Download className="h-4 w-4" />
                </Button>
              </div>
            </div>
          </div>

          {/* COMPACT SUMMARY STRIP (Digital Only) */}
          <div className="max-w-7xl mx-auto mt-4 pt-4 border-t border-slate-200 flex flex-wrap items-center justify-end gap-8">
            <div className="flex flex-col items-end">
              <span className="text-[8px] font-black uppercase text-slate-400 tracking-widest">Opening Balance</span>
              <span className={cn("text-xs font-bold num-audit", stats.opening >= 0 ? "text-slate-900" : "text-liabilities")}>
                {stats.opening === 0 ? "0.00" : `${formatNumber(Math.abs(stats.opening))} ${stats.opening >= 0 ? "Dr" : "Cr"}`}
              </span>
            </div>
            <div className="flex flex-col items-end border-l border-slate-200 pl-8">
              <span className="text-[8px] font-black uppercase text-slate-400 tracking-widest">Total Debit</span>
              <span className="text-xs font-bold num-audit text-assets">{formatNumber(stats.totalDebit)}</span>
            </div>
            <div className="flex flex-col items-end border-l border-slate-200 pl-8">
              <span className="text-[8px] font-black uppercase text-slate-400 tracking-widest">Total Credit</span>
              <span className="text-xs font-bold num-audit text-liabilities">{formatNumber(stats.totalCredit)}</span>
            </div>
            <div className="flex flex-col items-end bg-slate-900 px-4 py-1.5 ml-4">
              <span className="text-[8px] font-black uppercase text-slate-400 tracking-widest leading-none mb-1">Account Closing</span>
              <span className="text-sm font-black num-audit text-white leading-none">
                {stats.balance === 0 ? "0.00" : `${formatNumber(Math.abs(stats.balance))} ${stats.balance >= 0 ? "Dr" : "Cr"}`}
              </span>
            </div>
          </div>
        </div>

        {isLoading ? (
          <div className="flex flex-col items-center justify-center min-h-[50vh] gap-4 opacity-50">
            <Loader2 className="h-10 w-10 animate-spin text-slate-900" />
            <span className="text-[10px] font-black uppercase tracking-[0.3em] text-slate-500">Retrieving Ledger Records...</span>
          </div>
        ) : appliedParty ? (
          <div className="max-w-7xl mx-auto px-4 pt-8 pb-20 print:p-0 print-container-base">
            <div className="print-header flex justify-between items-baseline border-b-2 border-slate-900 pb-2 mb-6">
              <div className="flex flex-col">
                <h2 className="text-2xl font-black uppercase text-slate-900 tracking-tighter">Account Statement: {activeParty?.name}</h2>
                <span className="text-[9px] font-bold text-slate-500 uppercase tracking-widest">Business ID: {appliedParty.slice(0, 12)}...</span>
              </div>
              <div className="text-right">
                <span className="text-[10px] font-black text-slate-900 uppercase">Statement Period</span>
                <p className="text-xs font-bold text-slate-500">{formatClassicDate(appliedStart)} — {formatClassicDate(appliedEnd)}</p>
              </div>
            </div>

            {/* QUICK SUMMARY BOX (Print Only) */}
            <div className="print-summary-box print-only">
              <div className="print-summary-item">
                <span className="print-summary-label">Opening Balance</span>
                <span className="print-summary-value">
                  {formatNumber(Math.abs(stats.opening))}
                  <span className={cn("ml-1", stats.opening >= 0 ? "text-[#be123c]" : "text-[#15803d]")}>
                    {stats.opening >= 0 ? "DR" : "CR"}
                  </span>
                </span>
              </div>
              <div className="print-summary-item">
                <span className="print-summary-label">Total Purchases/Dr</span>
                <span className="print-summary-value">{formatNumber(stats.totalDebit)}</span>
              </div>
              <div className="print-summary-item">
                <span className="print-summary-label">Total Payments/Cr</span>
                <span className="print-summary-value">{formatNumber(stats.totalCredit)}</span>
              </div>
              <div className="print-summary-item">
                <span className="print-summary-label">Current Balance</span>
                <span className="print-summary-value">
                  {formatNumber(Math.abs(stats.balance))}
                  <span className={cn("ml-1", stats.balance >= 0 ? "text-[#be123c]" : "text-[#15803d]")}>
                    {stats.balance >= 0 ? "DR" : "CR"}
                  </span>
                </span>
              </div>
            </div>

            <div className="overflow-x-auto">
              <table className="ledger-table print-table w-full">
                <thead>
                  <tr>
                    <th className="w-24 px-4 py-3">Date</th>
                    <th className="w-28 px-4 py-3">Ref/Voucher</th>
                    <th className="px-4 py-3">Transaction Type</th>
                    <th className="right-align w-24 px-4 py-3 print-hidden">Qty (L)</th>
                    <th className="right-align w-24 px-4 py-3 print-hidden">Rate</th>
                    <th className="right-align w-32 px-4 py-3">Debit</th>
                    <th className="right-align w-32 px-4 py-3">Credit</th>
                    <th className="right-align w-40 px-4 py-3 bg-slate-100/50 print:bg-slate-50">Balance</th>
                  </tr>
                </thead>
                <tbody>
                  {rawStatement?.map((row, i) => {
                    const isOpening = row.voucher_no === 'OPEN';
                    const particulars = row.particulars.toLowerCase();
                    const vNo = row.voucher_no.toUpperCase();

                    const cleanedNote = row.particulars.replace(/^Ref: N\/A - /, "").replace(/^Ref: N\/A/, "").trim();
                    let typeLabel = cleanedNote || "Adjustment";

                    if (isOpening) {
                      typeLabel = "Opening Balance";
                    } else if (!cleanedNote) {
                      if (vNo.startsWith('PUR')) typeLabel = "Inventory Purchase";
                      else if (row.particulars.toLowerCase().includes('bank transfer')) typeLabel = "Bank Transfer";
                      else if (row.particulars.toLowerCase().includes('payment')) typeLabel = "Payment Received";
                    }

                    return (
                      <tr key={i} className={cn(
                        "hover:bg-slate-50/50 transition-colors",
                        isOpening ? "bg-slate-100/80 font-bold" : "",
                        row.is_reversed_entry ? "opacity-30 italic bg-rose-50/20" : ""
                      )}>
                        <td className="center-align num-audit text-[9px] text-slate-500">{formatClassicDate(row.posting_date)}</td>
                        <td className="font-mono text-[8px] text-slate-400 group">
                          <div className="flex items-center justify-between">
                            <span>{row.voucher_no}</span>
                            <button onClick={() => { setSelectedVoucher(row.voucher_no); setRevModalOpen(true); }} className="opacity-0 group-hover:opacity-100 p-0.5 hover:text-rose-600 print:hidden">
                              <RotateCcw className="h-2.5 w-2.5" />
                            </button>
                          </div>
                        </td>
                        <td className={cn("uppercase font-bold tracking-tight text-[10px] text-slate-900 px-4", row.is_reversed_entry && "line-through grayscale")}>
                          {typeLabel}
                        </td>
                        <td className="right-align num-audit text-slate-500 font-medium print-hidden">{(row.quantity || row.qty || 0) > 0 ? formatNumber(row.quantity || row.qty || 0) : '-'}</td>
                        <td className="right-align num-audit text-slate-400 print-hidden">{(row.rate || 0) > 0 ? formatNumber(row.rate) : '-'}</td>
                        <td className="right-align num-audit font-bold text-slate-700">{row.debit > 0 ? formatNumber(row.debit) : '-'}</td>
                        <td className="right-align num-audit font-bold text-slate-700">{row.credit > 0 ? formatNumber(row.credit) : '-'}</td>
                        <td className={cn(
                          "right-align num-audit font-black text-[11px] bg-slate-50/30",
                          row.running_balance > 0 ? "text-assets print:text-[#be123c]" : row.running_balance < 0 ? "text-liabilities print:text-[#15803d]" : "text-slate-300"
                        )}>
                          {row.running_balance === 0 ? "0.00" : formatNumber(Math.abs(row.running_balance))}
                          {row.running_balance !== 0 && (
                            <span className={cn(
                              "text-[7px] ml-1 font-black",
                              row.running_balance > 0 ? "text-[#be123c]" : "text-[#15803d]"
                            )}>
                              {row.running_balance > 0 ? "DR" : "CR"}
                            </span>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>

            <div className="mt-8 flex flex-wrap gap-4 print:hidden">
              {productSummary?.map((ps, i) => (
                <div key={i} className="border-l-4 border-slate-900 bg-slate-50 px-4 py-2 flex flex-col min-w-[140px]">
                  <span className="text-[8px] font-black text-slate-500 uppercase tracking-widest">{ps.fuel_name} Summary</span>
                  <span className="num-audit text-lg font-black">{formatNumber(ps.total_qty)} <span className="text-[10px] font-normal">Litres</span></span>
                </div>
              ))}
            </div>

            <div className="mt-12 text-center text-[9px] text-slate-400 font-bold uppercase tracking-[0.2em] print-only pt-8 border-t border-slate-100">
              End of Account Statement - Thank you for your business
            </div>
          </div>
        ) : (
          <div className="max-w-7xl mx-auto px-4 py-40 flex flex-col items-center justify-center opacity-20">
            <ShieldCheck className="h-20 w-20 text-slate-900 mb-6" />
            <h2 className="text-lg font-black uppercase tracking-[0.4em] text-slate-900">Audit Terminal Standby</h2>
            <p className="text-[10px] font-bold uppercase tracking-widest mt-2">Select khata to begin session</p>
          </div>
        )}
      </div>

      <ReversalModal isOpen={revModalOpen} voucherNo={selectedVoucher} onClose={() => setRevModalOpen(false)} />
    </DashboardLayout>
  );
}
