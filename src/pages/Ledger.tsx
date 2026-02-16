
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatDate, formatNumber } from '@/lib/format';
import { useMemo } from 'react';
import { cn } from '@/lib/utils';
import { Loader2, X, BookOpen, RotateCcw, Calendar, Download, Printer, Check, ChevronsUpDown } from 'lucide-react';
import { ReversalModal } from '@/components/modals/ReversalModal';
import { Card } from '@/components/ui/card';
import { useAuth } from '@/contexts/AuthContext';

import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";

export default function Ledger() {
  const today = new Date();
  const firstDayOfMonth = new Date(today.getFullYear(), today.getMonth(), 1);

  const [selectedEntityId, setSelectedEntityId] = useState<string>('');
  const [selectedEntityType, setSelectedEntityType] = useState<string>('');
  const [startDate, setStartDate] = useState<string>(firstDayOfMonth.toISOString().split('T')[0]);
  const [endDate, setEndDate] = useState<string>(today.toISOString().split('T')[0]);
  const [revModalOpen, setRevModalOpen] = useState(false);
  const [selectedVoucher, setSelectedVoucher] = useState<string | null>(null);
  const [comboboxOpen, setComboboxOpen] = useState(false);
  const [comboboxFilter, setComboboxFilter] = useState('');
  const { user } = useAuth();

  // Audit Hash Generator
  const reportHash = useMemo(() => {
    if (!selectedEntityId) return '';
    const dateStr = new Date().toISOString().split('T')[0].replace(/-/g, '');
    const randomSuffix = Math.random().toString(36).substring(2, 6).toUpperCase();
    return `LDR-${dateStr}-${selectedEntityId.slice(0, 4).toUpperCase()}-${randomSuffix}`;
  }, [selectedEntityId]);

  // Export CSV Helper
  const exportToCSV = (data: any[]) => {
    if (!data || data.length === 0) return;
    const headers = ["Date", "Voucher", "Particulars", "Qty", "Rate", "Debit", "Credit", "Balance"].join(",");
    const rows = data.map(row => [
      row.posting_date,
      row.voucher_no,
      `"${(row.particulars || '').replace(/"/g, '""')}"`,
      row.qty || 0,
      row.rate || 0,
      row.debit || 0,
      row.credit || 0,
      row.running_balance || 0
    ].join(","));
    const csv = [headers, ...rows].join("\n");
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.setAttribute('hidden', '');
    a.setAttribute('href', url);
    a.setAttribute('download', `Ledger_${selectedEntityId}_${formatDate(new Date().toISOString())}.csv`);
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  };

  // Fetch All Entities Combined
  const { data: allEntities, isLoading: loadingEntities } = useQuery({
    queryKey: ['unified-entities-fresh'],
    queryFn: async () => {
      const [partiesRes, accRes] = await Promise.all([
        supabase.from('parties').select('id, name, type').eq('is_active', true),
        supabase.from('accounts').select('id, name, code, account_type').eq('is_active', true)
      ]);

      const parties = (partiesRes.data || []).map(p => ({
        id: p.id,
        name: p.name,
        type: 'party',
        originalType: p.type
      }));

      // Simplified accounts: Only show Cash, Bank, and Proprietor Capital to the Munshi
      const accounts = (accRes.data || [])
        .filter(a =>
          a.code === '1000' ||
          a.code === '1010' ||
          a.code === '3010' ||
          a.name.toLowerCase().includes('cash') ||
          a.name.toLowerCase().includes('bank') ||
          a.name.toLowerCase().includes('capital')
        )
        .map(a => ({
          id: a.id,
          name: a.name,
          type: 'account',
          originalType: a.account_type // Use real classification from DB
        }));

      return [...parties, ...accounts].sort((a, b) => a.name.localeCompare(b.name));
    }
  });

  // Fetch Munshi Statement via RPC
  const { data: statementEntries, isLoading: loadingLedger } = useQuery({
    queryKey: ['party-statement', selectedEntityId, startDate, endDate],
    enabled: !!selectedEntityId && selectedEntityType === 'party',
    queryFn: async () => {
      const { data, error } = await (supabase as any).rpc('get_party_statement', {
        p_party_id: selectedEntityId,
        p_start_date: startDate,
        p_end_date: endDate
      });
      if (error) throw error;
      return data;
    }
  });

  // Enhanced Fetch for General Accounts (Non-Party)
  const { data: accountEntries, isLoading: loadingAccount } = useQuery({
    queryKey: ['account-ledger', selectedEntityId, startDate, endDate],
    enabled: !!selectedEntityId && selectedEntityType === 'account',
    queryFn: async () => {
      // 1. Calculate Opening Balance manually for the selected range
      const { data: opData } = await supabase
        .from('ledger_entries')
        .select('debit_amount, credit_amount')
        .eq('account_id', selectedEntityId)
        .lt('posting_date', startDate);

      const openingBalance = (opData || []).reduce((acc, curr) => acc + (Number(curr.debit_amount) - Number(curr.credit_amount)), 0);

      // 2. Fetch Entries in range
      const { data, error } = await supabase
        .from('ledger_entries')
        .select('posting_date, voucher_no, narration, debit_amount, credit_amount, created_at, voucher_type')
        .eq('account_id', selectedEntityId)
        .gte('posting_date', startDate)
        .lte('posting_date', endDate)
        .order('posting_date', { ascending: true })
        .order('created_at', { ascending: true })
        .order('voucher_no', { ascending: true });

      if (error) throw error;

      let currentBalance = openingBalance;

      const entries = [
        {
          posting_date: startDate,
          voucher_no: 'OPEN',
          particulars: 'Opening Balance B/F',
          debit: openingBalance >= 0 ? openingBalance : 0,
          credit: openingBalance < 0 ? Math.abs(openingBalance) : 0,
          running_balance: openingBalance,
          details: 'SYSTEM'
        },
        ...(data || []).map(d => {
          currentBalance += (Number(d.debit_amount) - Number(d.credit_amount));
          return {
            posting_date: d.posting_date,
            voucher_no: d.voucher_no,
            particulars: d.narration || 'General Entry',
            details: d.voucher_type,
            debit: d.debit_amount,
            credit: d.credit_amount,
            running_balance: currentBalance,
            quantity_display: '-',
            rate_display: '-'
          };
        })
      ];
      return entries;
    }
  });

  const ledgerEntries = selectedEntityType === 'party' ? (statementEntries as any[]) : (accountEntries as any[]);

  const stats = useMemo(() => {
    if (!ledgerEntries || ledgerEntries.length === 0) return { totalDebit: 0, totalCredit: 0, closing: 0 };
    const validEntries = ledgerEntries.filter(e => e.voucher_no !== 'OPEN');
    const totalDebit = validEntries.reduce((acc, curr) => acc + (Number(curr.debit) || 0), 0);
    const totalCredit = validEntries.reduce((acc, curr) => acc + (Number(curr.credit) || 0), 0);
    const closing = ledgerEntries[ledgerEntries.length - 1]?.running_balance || 0;
    return { totalDebit, totalCredit, closing };
  }, [ledgerEntries]);

  const activeEntity = allEntities?.find(e => e.id === selectedEntityId);

  return (

    <DashboardLayout>
      <div className="max-w-[1600px] mx-auto pb-20 print:p-0 print:m-0">

        {/* PURE ERP MINIMALIST PRINT STYLING */}
        <style dangerouslySetInnerHTML={{
          __html: `
          @media print {
            @page { 
              size: A4; 
              margin: 0 !important; 
            }
            html, body { 
              height: auto !important;
              background: #fff !important; 
              color: #000 !important; 
              font-family: "Inter", sans-serif !important; 
              -webkit-print-color-adjust: exact;
            }
            .print-only { 
              display: block !important; 
              padding: 1.5cm !important;
            }
            .web-only, .no-print, header, footer, nav, aside, [role="navigation"] { display: none !important; }

            .audit-table { width: 100%; border-collapse: collapse; margin-top: 15px; border: 0.5pt solid #000; }
            .audit-table th { padding: 8px 6px; border: 0.5pt solid #000; background: #f8fafc !important; font-size: 7.5pt; font-weight: 800; text-align: left; text-transform: uppercase; }
            .audit-table td { padding: 6px; border: 0.5pt solid #eee; font-size: 7.5pt; vertical-align: middle; white-space: nowrap; }
            .particulars-cell { white-space: nowrap !important; overflow: hidden; text-overflow: ellipsis; max-width: 350px; }
            
            .summary-block { display: grid; grid-template-cols: repeat(4, 1fr); gap: 1px; background: #000; border: 1pt solid #000; margin-bottom: 20px; }
            .summary-item { background: #fff; padding: 10px; }
            .summary-label { font-size: 6pt; font-weight: 800; color: #666; text-transform: uppercase; display: block; margin-bottom: 2px; }
            .summary-value { font-size: 9pt; font-weight: 900; color: #000; }

            .signature-block { display: grid; grid-template-cols: repeat(3, 1fr); gap: 40px; margin-top: 50px; text-align: center; }
            .sign-line { border-top: 1pt solid #000; padding-top: 5px; font-size: 7pt; font-weight: 700; text-transform: uppercase; }
            .footer-legal { position: fixed; bottom: 1cm; left: 1.5cm; right: 1.5cm; font-size: 6.5pt; color: #999; text-align: center; border-top: 0.5pt solid #eee; padding-top: 10px; }
          }
          .print-only { display: none; }
        `}} />

        {/* --- PURE ERP HEADER --- */}
        <div className="print-only">
          <div className="flex justify-between items-start border-b-2 border-black pb-4 mb-6">
            <div>
              <h1 className="text-xl font-black text-black leading-none uppercase tracking-tight">Naveed Musazai</h1>
              <p className="text-[7.5pt] font-bold text-slate-500 mt-1 uppercase">Official Financial Report | General Ledger</p>
            </div>
            <div className="text-right">
              <span className="text-[6.5pt] font-black text-slate-400 block uppercase">Report Control ID</span>
              <span className="text-[9pt] font-mono font-bold text-black">{reportHash}</span>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-10 mb-6">
            <div className="grid grid-cols-[120px_1fr] gap-x-4 gap-y-2">
              <span className="text-[7pt] font-bold text-slate-400 uppercase">Account Name</span>
              <span className="text-[7pt] font-black text-black uppercase">{activeEntity?.name}</span>

              <span className="text-[7pt] font-bold text-slate-400 uppercase">Classification</span>
              <span className="text-[7pt] font-bold text-black uppercase">
                {activeEntity?.type === 'party'
                  ? (activeEntity?.originalType === 'supplier' ? 'Trade Payable' : 'Trade Receivable')
                  : (activeEntity?.originalType || 'Financial Asset')
                }
              </span>

              <span className="text-[7pt] font-bold text-slate-400 uppercase">Currency</span>
              <span className="text-[7pt] font-bold text-black uppercase">PKR</span>
            </div>

            <div className="grid grid-cols-[120px_1fr] gap-x-4 gap-y-2 text-right">
              <span className="text-[7pt] font-bold text-slate-400 uppercase">Fiscal Period</span>
              <span className="text-[7pt] font-bold text-black">{formatDate(startDate)} — {formatDate(endDate)}</span>

              <span className="text-[7pt] font-bold text-slate-400 uppercase">Record Status</span>
              <span className="text-[7pt] font-bold text-emerald-700 uppercase">Posted / Finalized</span>

              <span className="text-[7pt] font-bold text-slate-400 uppercase">Prepared By</span>
              <span className="text-[7pt] font-bold text-black uppercase">{user?.email?.split('@')[0] || 'System Operator'}</span>
            </div>
          </div>

          {/* ERP DYNAMIC SUMMARY BLOCK */}
          <div className="summary-block">
            <div className="summary-item">
              <span className="summary-label">Opening Balance</span>
              <div className="summary-value">
                {ledgerEntries && ledgerEntries.length > 0 ? (
                  <>
                    {formatNumber(Math.abs((ledgerEntries[0].running_balance || 0) - (ledgerEntries[0].debit || 0) + (ledgerEntries[0].credit || 0)))}
                    {' '}{(ledgerEntries[0].running_balance || 0) - (ledgerEntries[0].debit || 0) + (ledgerEntries[0].credit || 0) >= 0 ? 'Dr' : 'Cr'}
                  </>
                ) : '0.00 Dr'}
              </div>
            </div>
            <div className="summary-item">
              <span className="summary-label">Period Debit</span>
              <div className="summary-value text-rose-700">{formatNumber(stats.totalDebit)}</div>
            </div>
            <div className="summary-item">
              <span className="summary-label">Period Credit</span>
              <div className="summary-value text-emerald-700">{formatNumber(stats.totalCredit)}</div>
            </div>
            <div className="summary-item bg-slate-50">
              <span className="summary-label">Closing Position</span>
              <div className="summary-value">
                {formatNumber(Math.abs(stats.closing))} {stats.closing >= 0 ? 'Dr' : 'Cr'}
              </div>
            </div>
          </div>

          <table className="audit-table">
            <thead>
              <tr>
                <th className="w-[80px]">Date</th>
                <th className="w-[100px]">Reference</th>
                <th>Particulars</th>
                <th className="w-[100px] right-align">Debit (PKR)</th>
                <th className="w-[100px] right-align">Credit (PKR)</th>
                <th className="w-[110px] right-align">Balance</th>
                <th className="w-[40px] center-align">Type</th>
              </tr>
            </thead>
            <tbody>
              {ledgerEntries?.map((entry: any, i: number) => {
                const balance = entry.running_balance || 0;
                return (
                  <tr key={i}>
                    <td>{formatDate(entry.posting_date)}</td>
                    <td className="font-mono text-[6.5pt] tracking-tighter text-slate-500">{entry.voucher_no}</td>
                    <td className="particulars-cell font-bold uppercase tracking-tight">
                      {entry.particulars.replace(/^Ref: N\/A - /, "").replace(/Adjustment/, "Adjustment").replace(/SOLIDIFICATION/, "Adjustment").replace(/OPENING BALANCE/, "OP-BAL").trim()}
                      {entry.fuel_name && <span className="ml-2 font-medium text-slate-400 italic text-[6.5pt]">({entry.fuel_name})</span>}
                    </td>
                    <td className="right-align">{(entry.debit || 0) > 0 ? formatNumber(entry.debit) : '—'}</td>
                    <td className="right-align">{(entry.credit || 0) > 0 ? formatNumber(entry.credit) : '—'}</td>
                    <td className="right-align font-black text-black">{formatNumber(Math.abs(balance))}</td>
                    <td className="center-align font-black text-[7pt]">{balance >= 0 ? 'Dr' : 'Cr'}</td>
                  </tr>
                );
              })}
            </tbody>
            <tfoot>
              <tr>
                <td colSpan={3} className="text-right font-black uppercase text-[7pt] px-4">Period Movement Totals:</td>
                <td className="right-align font-black border-t-2 border-black">{formatNumber(stats.totalDebit)}</td>
                <td className="right-align font-black border-t-2 border-black">{formatNumber(stats.totalCredit)}</td>
                <td className="right-align font-black border-t-2 border-black bg-slate-50">{formatNumber(Math.abs(stats.closing))}</td>
                <td className="center-align font-black border-t-2 border-black bg-slate-50">{stats.closing >= 0 ? 'Dr' : 'Cr'}</td>
              </tr>
            </tfoot>
          </table>


          <div className="footer-legal">
            System Generated Financial Resource Planning (ERP) Record | Transaction Control ID: {reportHash} | Generated: {new Date().toLocaleString()}
          </div>
        </div>


        {/* =================================================================
            2. WEB VIEW LAYER (Only shows on browser)
            ================================================================= */}
        <div className="web-only">
          {/* STICKY FILTER BAR */}
          <div className="sticky-filter-bar px-6">
            <div className="max-w-[1600px] mx-auto flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6">
              <div className="report-header mb-0">
                <h1 className="report-title">General Ledger Register</h1>
                <p className="report-subtitle">Consolidated Statement of Accounts, Customers & Suppliers</p>
              </div>

              <div className="flex flex-wrap items-center gap-2">
                <Button variant="outline" className="rounded-none font-bold uppercase text-[10px] tracking-widest gap-2 border-slate-300 h-9" onClick={() => window.print()}>
                  <Printer className="h-4 w-4" /> Print Statement
                </Button>
                <Button variant="outline" className="rounded-none font-bold uppercase text-[10px] tracking-widest gap-2 border-slate-300 h-9" onClick={() => exportToCSV(ledgerEntries)}>
                  <Download className="h-4 w-4" /> Export CSV
                </Button>
              </div>
            </div>

            <div className="mt-6 grid grid-cols-1 lg:grid-cols-12 gap-3 items-end bg-slate-50 p-3 border border-slate-200">
              <div className="lg:col-span-5 space-y-1">
                <Label className="text-[9px] font-black uppercase tracking-widest text-slate-500">Account Selection</Label>
                <Popover open={comboboxOpen} onOpenChange={setComboboxOpen}>
                  <PopoverTrigger asChild>
                    <Button variant="outline" role="combobox" className="w-full h-10 justify-between bg-white border-slate-300 rounded-none px-4 font-bold text-xs">
                      {selectedEntityId ? allEntities?.find((e: any) => e.id === selectedEntityId)?.name : "Search Customer or General Account..."}
                      <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
                    </Button>
                  </PopoverTrigger>
                  <PopoverContent className="w-[var(--radix-popover-trigger-width)] p-0 bg-white border border-slate-900 rounded-none shadow-none">
                    <div className="rounded-none">
                      <input
                        placeholder="Type to filter..."
                        className="h-10 w-full border-none border-b border-slate-200 px-4 font-bold uppercase text-xs focus:ring-0 focus:outline-none"
                        value={comboboxFilter}
                        onChange={(e) => setComboboxFilter(e.target.value)}
                        autoFocus
                      />
                      <div className="max-h-[300px] overflow-y-auto border-t border-slate-200">
                        {(() => {
                          const filtered = allEntities?.filter((entity: any) =>
                            entity.name.toLowerCase().includes(comboboxFilter.toLowerCase())
                          );
                          if (!filtered || filtered.length === 0) {
                            return <div className="py-6 text-center text-slate-500 text-xs italic">No matching record found in directory.</div>;
                          }
                          return filtered.map((entity: any) => (
                            <div
                              key={entity.id}
                              onClick={() => { setSelectedEntityId(entity.id); setSelectedEntityType(entity.type); setComboboxOpen(false); setComboboxFilter(''); }}
                              className="flex flex-col items-start py-2 px-4 cursor-pointer hover:bg-slate-100 rounded-none"
                            >
                              <span className="font-bold text-slate-900 uppercase text-xs">{entity.name}</span>
                              <span className="text-[8px] font-black uppercase text-slate-400">{entity.originalType}</span>
                            </div>
                          ));
                        })()}
                      </div>
                    </div>
                  </PopoverContent>
                </Popover>
              </div>

              <div className="lg:col-span-3 space-y-1">
                <Label className="text-[9px] font-black uppercase text-slate-500">Statement From</Label>
                <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} className="w-full h-10 px-3 bg-white border border-slate-300 rounded-none font-bold text-xs focus:border-slate-900 outline-none" />
              </div>

              <div className="lg:col-span-3 space-y-1">
                <Label className="text-[9px] font-black uppercase text-slate-500">Statement To</Label>
                <input type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} className="w-full h-10 px-3 bg-white border border-slate-300 rounded-none font-bold text-xs focus:border-slate-900 outline-none" />
              </div>

              <div className="lg:col-span-1">
                <Button variant="outline" className="h-10 w-full rounded-none border-slate-300 bg-white" onClick={() => { setSelectedEntityId(''); setSelectedEntityType(''); }}>
                  <X className="h-4 w-4" />
                </Button>
              </div>
            </div>
          </div>

          {/* MAIN CONTENT WEB VIEW */}
          <div className="px-6 space-y-8 mt-8">
            {selectedEntityId && (
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                <div className="summary-card">
                  <span className="summary-label">Total Listings (Dr)</span>
                  <span className="summary-value text-liabilities text-xl">{formatPKR(stats.totalDebit)}</span>
                </div>
                <div className="summary-card">
                  <span className="summary-label">Total Direct (Cr)</span>
                  <span className="summary-value text-assets text-xl">{formatPKR(stats.totalCredit)}</span>
                </div>
                <div className={cn("summary-card sm:col-span-2 border-l-4", stats.closing >= 0 ? "border-l-rose-500 bg-rose-50/10" : "border-l-emerald-500 bg-emerald-50/10")}>
                  <span className="summary-label">Net Settlement Position</span>
                  <div className="flex items-center gap-4">
                    <span className="text-3xl font-black num-audit text-slate-900">{stats.closing === 0 ? "0.00" : formatNumber(Math.abs(stats.closing))}</span>
                    {stats.closing !== 0 && (
                      <span className={cn("px-3 py-1 font-black text-[10px] uppercase border", stats.closing >= 0 ? "text-rose-700 border-rose-200" : "text-emerald-700 border-emerald-200")}>
                        {stats.closing >= 0 ? 'Receivable (Dr)' : 'Payable (Cr)'}
                      </span>
                    )}
                  </div>
                </div>
              </div>
            )}

            <div className="min-h-[400px]">
              {loadingLedger || loadingAccount ? (
                <div className="flex flex-col items-center justify-center min-h-[40vh] gap-4">
                  <Loader2 className="h-10 w-10 animate-spin text-slate-300" />
                  <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-400">Compiling Ledger Records...</span>
                </div>
              ) : !selectedEntityId ? (
                <div className="center-align py-32 border border-dashed border-slate-300 opacity-50">
                  <BookOpen className="h-10 w-10 mx-auto mb-4 text-slate-300" />
                  <p className="font-bold uppercase text-[10px] tracking-widest">Select an account to generate ledger</p>
                </div>
              ) : (ledgerEntries && ledgerEntries.length > 0 ? (
                <div className="border border-slate-300 overflow-hidden">
                  <div className="overflow-x-auto">
                    <table className="ledger-table">
                      <thead>
                        <tr className="bg-slate-900">
                          <th className="w-28 !text-white">Date</th>
                          <th className="w-32 !text-white">Voucher No</th>
                          <th className="!text-white">Particulars / Journal Details</th>
                          <th className="right-align w-32 !text-white">Debit (Out)</th>
                          <th className="right-align w-32 !text-white">Credit (In)</th>
                          <th className="right-align w-40 bg-slate-950 !text-white">Balance</th>
                        </tr>
                      </thead>
                      <tbody>
                        {ledgerEntries.map((entry: any, idx: number) => {
                          const balance = entry.running_balance || 0;
                          return (
                            <tr key={idx} className="hover:bg-slate-50">
                              <td className="num-audit font-bold">{formatDate(entry.posting_date)}</td>
                              <td className="num-audit !text-[8px] text-slate-400">{entry.voucher_no}</td>
                              <td>
                                <div className="flex flex-col">
                                  <span className="font-bold text-slate-900 uppercase leading-none tracking-tight">{entry.particulars.replace(/^Ref: N\/A - /, "").trim()}</span>
                                  {entry.fuel_name && <span className="text-[8px] font-black text-slate-400 uppercase mt-1">Product: {entry.fuel_name}</span>}
                                </div>
                              </td>
                              <td className="right-align num-audit font-bold text-liabilities">{(entry.debit || 0) > 0 ? formatNumber(entry.debit) : '—'}</td>
                              <td className="right-align num-audit font-bold text-assets">{(entry.credit || 0) > 0 ? formatNumber(entry.credit) : '—'}</td>
                              <td className="right-align bg-slate-50/50">
                                <span className="num-audit font-black text-slate-900 text-sm">{formatNumber(Math.abs(balance))}</span>
                                <span className={cn("ml-1.5 text-[8px] font-black uppercase", balance >= 0 ? 'text-rose-600' : 'text-emerald-600')}>
                                  {balance >= 0 ? 'Dr' : 'Cr'}
                                </span>
                              </td>
                            </tr>
                          )
                        })}
                      </tbody>
                    </table>
                  </div>
                </div>
              ) : (
                <div className="center-align py-32 border border-slate-200 opacity-50">
                  <p className="italic text-sm">No transactions recorded for the selected period.</p>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>

      <ReversalModal
        isOpen={revModalOpen}
        voucherNo={selectedVoucher}
        onClose={() => setRevModalOpen(false)}
      />
    </DashboardLayout>
  );
}
