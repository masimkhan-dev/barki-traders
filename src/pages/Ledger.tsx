
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
import { BrandTitle } from '@/components/brand/BrandTitle';
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

      // Expanded accounts: Show Cash, Bank, Capital, Expenses, and Income to the user
      const accounts = (accRes.data || [])
        .filter(a =>
          ['asset', 'liability', 'equity', 'expense', 'income'].includes(a.account_type)
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

  const activeEntity = allEntities?.find(e => e.id === selectedEntityId);
  const activeAccountName = String(activeEntity?.name || '').toLowerCase();
  const controlAccountKind =
    selectedEntityType === 'account' && activeAccountName.includes('receivable')
      ? 'receivable'
      : selectedEntityType === 'account' && activeAccountName.includes('payable')
        ? 'payable'
        : null;

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
    queryKey: ['account-ledger', selectedEntityId, startDate, endDate, controlAccountKind],
    enabled: !!selectedEntityId && selectedEntityType === 'account',
    queryFn: async () => {
      if (controlAccountKind) {
        const [partiesRes, entriesRes] = await Promise.all([
          supabase
            .from('parties')
            .select('id, name, type')
            .eq('is_active', true),
          supabase
            .from('ledger_entries')
            .select('party_id, posting_date, debit_amount, credit_amount')
            .not('party_id', 'is', null)
            .lte('posting_date', endDate)
        ]);

        if (partiesRes.error) throw partiesRes.error;
        if (entriesRes.error) throw entriesRes.error;

        const partyMap = new Map((partiesRes.data || []).map(p => [p.id, p]));
        const balances = new Map<string, { balance: number; lastDate: string | null }>();

        (entriesRes.data || []).forEach(entry => {
          if (!entry.party_id) return;
          const current = balances.get(entry.party_id) || { balance: 0, lastDate: null };
          current.balance += (Number(entry.debit_amount) || 0) - (Number(entry.credit_amount) || 0);
          if (!current.lastDate || String(entry.posting_date) > current.lastDate) {
            current.lastDate = String(entry.posting_date);
          }
          balances.set(entry.party_id, current);
        });

        let runningBalance = 0;
        const controlRows = Array.from(balances.entries())
          .map(([partyId, value]) => {
            const party = partyMap.get(partyId);
            return {
              partyName: party?.name || 'Unknown Party',
              partyType: party?.type || 'party',
              balance: value.balance,
              lastDate: value.lastDate || endDate,
            };
          })
          .filter(row =>
            controlAccountKind === 'receivable'
              ? row.balance > 0
              : row.balance < 0
          )
          .sort((a, b) => a.partyName.localeCompare(b.partyName))
          .map((row, idx) => {
            runningBalance += row.balance;
            return {
              posting_date: row.lastDate,
              voucher_no: `${controlAccountKind === 'receivable' ? 'AR' : 'AP'}-${String(idx + 1).padStart(3, '0')}`,
              particulars: `${row.partyName} closing ${controlAccountKind === 'receivable' ? 'receivable' : 'payable'}`,
              details: row.partyType,
              debit: row.balance > 0 ? row.balance : 0,
              credit: row.balance < 0 ? Math.abs(row.balance) : 0,
              running_balance: runningBalance,
              quantity_display: '-',
              rate_display: '-'
            };
          });

        return [
          {
            posting_date: startDate,
            voucher_no: 'OPEN',
            particulars: 'Opening Balance B/F',
            debit: 0,
            credit: 0,
            running_balance: 0,
            details: 'SYSTEM'
          },
          ...controlRows
        ];
      }

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
    if (!ledgerEntries || ledgerEntries.length === 0) return { opening: 0, totalDebit: 0, totalCredit: 0, closing: 0 };
    const openingEntry = ledgerEntries.find(e => e.voucher_no === 'OPEN');
    const opening = openingEntry ? (Number(openingEntry.running_balance) || 0) : 0;
    const validEntries = ledgerEntries.filter(e => e.voucher_no !== 'OPEN');
    const totalDebit = validEntries.reduce((acc, curr) => acc + (Number(curr.debit) || 0), 0);
    const totalCredit = validEntries.reduce((acc, curr) => acc + (Number(curr.credit) || 0), 0);
    const closing = ledgerEntries[ledgerEntries.length - 1]?.running_balance || 0;
    return { opening, totalDebit, totalCredit, closing };
  }, [ledgerEntries]);

  return (

    <DashboardLayout>
      <div className="max-w-[1600px] mx-auto pb-20 print:p-0 print:m-0">

        {/* PURE ERP MINIMALIST PRINT STYLING */}
        <style dangerouslySetInnerHTML={{
          __html: `
          @media print {
            @page { 
              size: A4 landscape; 
              margin: 10mm !important; 
            }
            html, body { 
              height: auto !important;
              background: #fff !important; 
              color: #000 !important; 
              font-family: "Inter", sans-serif !important; 
              -webkit-print-color-adjust: exact;
              print-color-adjust: exact;
            }
            .print-only { 
              display: block !important; 
              padding: 0 !important;
            }
            .web-only, .no-print, header, footer, nav, aside, [role="navigation"] { display: none !important; }

            .panels-row {
              display: flex !important;
              justify-content: space-between !important;
              gap: 15px !important;
              margin-bottom: 15px !important;
            }
            .panel-box {
              flex: 1 !important;
              border: 1px solid #cbd5e1 !important;
              page-break-inside: avoid !important;
              display: flex !important;
              flex-direction: column !important;
            }
            .panel-header {
              background-color: #0f766e !important;
              color: white !important;
              padding: 4px 8px !important;
              font-size: 9.5px !important;
              font-weight: 900 !important;
              text-transform: uppercase !important;
              letter-spacing: 0.05em !important;
            }
            .panel-body {
              padding: 8px 10px !important;
              font-size: 9px !important;
              color: #1e293b !important;
              line-height: 1.4 !important;
              display: flex !important;
              flex-direction: column !important;
              gap: 4px !important;
              flex: 1 !important;
            }
            .panel-body-summary-row {
              display: flex !important;
              justify-content: space-between !important;
              padding: 1px 0 !important;
              border-bottom: 1px dashed #e2e8f0 !important;
              font-family: 'JetBrains Mono', monospace !important;
              font-weight: 700 !important;
            }
            .panel-body-summary-row:last-child {
              border-bottom: none !important;
              font-weight: 900 !important;
              font-size: 10px !important;
              border-top: 1px solid #0f172a !important;
              margin-top: 3px !important;
              padding-top: 4px !important;
            }

            .audit-table { width: 100%; border-collapse: collapse; margin-top: 15px; border: 1.2pt solid #000; }
            .audit-table th { padding: 5px 4px; border: 1.2pt solid #1e293b; background-color: #0f766e !important; color: white !important; font-size: 8.5pt; font-weight: 900; text-align: left; text-transform: uppercase; }
            .audit-table td { padding: 3px 4px; border: 0.5pt solid #cbd5e1; font-size: 8pt; vertical-align: middle; white-space: nowrap; line-height: 1.1 !important; }
            .audit-table tr { break-inside: avoid !important; }
            .particulars-cell { white-space: nowrap !important; overflow: hidden; text-overflow: ellipsis; max-width: 350px; }
            
            .right-align { text-align: right !important; }
            .center-align { text-align: center !important; }

            .signature-block { display: grid; grid-template-cols: repeat(3, 1fr); gap: 40px; margin-top: 40px; text-align: center; break-inside: avoid !important; }
            .sign-line { border-top: 1pt solid #000; padding-top: 5px; font-size: 7.5pt; font-weight: 700; text-transform: uppercase; }
            .footer-legal { position: fixed; bottom: 5mm; left: 10mm; right: 10mm; font-size: 6.5pt; color: #999; text-align: center; border-top: 0.5pt solid #eee; padding-top: 10px; }
          }
          .print-only { display: none; }
        `}} />

        {/* --- PURE ERP HEADER --- */}
        <div className="print-only">
          {/* THREE-PANEL HEADER */}
          <div className="panels-row select-none">
            {/* Column 1: Branding & Control ID */}
            <div className="panel-box">
              <div className="panel-header flex justify-between items-center">
                <span>OFFICIAL REPORT | LEDGER</span>
                <span className="font-mono text-[8.5px] tracking-tight">{reportHash}</span>
              </div>
              <div className="p-3 flex items-center gap-3 bg-white flex-1">
                <div className="h-10 w-10 bg-[#0f766e] text-white font-black text-lg flex items-center justify-center shrink-0">
                  BKI
                </div>
                <div className="flex flex-col">
                  <span className="font-black text-xs text-slate-900 tracking-tight leading-none uppercase">BARKI TRADERS</span>
                  <span className="text-[8px] font-bold text-slate-400 mt-1 leading-none">PETROLEUM DISTRIBUTORS & FUEL SUPPLIERS</span>
                  <span className="text-[7.5px] font-medium text-slate-500 mt-0.5 leading-none">
                    Main G.T Road Opp Union Office Near PSO Depot Taru Jabba | Cell: 0310-9771002 | Email: iftikharmehtab321@gmail.com
                  </span>
                </div>
              </div>
            </div>

            {/* Column 2: Account Details */}
            <div className="panel-box">
              <div className="panel-header">
                ACCOUNT DETAILS:
              </div>
              <div className="panel-body font-bold flex flex-col justify-between flex-1">
                <div className="flex justify-between">
                  <span className="text-slate-400 uppercase">Account Name:</span>
                  <span className="text-slate-900 uppercase font-black">{activeEntity?.name}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-slate-400 uppercase">Classification:</span>
                  <span className="text-slate-900 uppercase">
                    {activeEntity?.type === 'party'
                      ? (activeEntity?.originalType === 'supplier'
                          ? 'Trade Payable'
                          : activeEntity?.originalType === 'customer'
                            ? 'Trade Receivable'
                            : 'Trade Customer & Supplier')
                      : (activeEntity?.originalType || 'Financial Asset')
                    }
                  </span>
                </div>
                <div className="flex justify-between">
                  <span className="text-slate-400 uppercase">Fiscal Period:</span>
                  <span className="text-slate-900">{formatDate(startDate)} — {formatDate(endDate)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-slate-400 uppercase">Prepared By:</span>
                  <span className="text-slate-900 uppercase">{user?.email?.split('@')[0] || 'System Operator'}</span>
                </div>
              </div>
            </div>

            {/* Column 3: Summary */}
            <div className="panel-box">
              <div className="panel-header">
                PERIOD SUMMARY:
              </div>
              <div className="panel-body font-mono font-bold flex flex-col justify-between flex-1">
                <div className="panel-body-summary-row">
                  <span className="text-slate-400">Opening Balance:</span>
                  <span className="text-slate-900">
                    {ledgerEntries && ledgerEntries.length > 0 ? (
                      <>
                        {formatNumber(Math.abs((ledgerEntries[0].running_balance || 0) - (ledgerEntries[0].debit || 0) + (ledgerEntries[0].credit || 0)))}
                        {' '}{(ledgerEntries[0].running_balance || 0) - (ledgerEntries[0].debit || 0) + (ledgerEntries[0].credit || 0) >= 0 ? 'Dr' : 'Cr'}
                      </>
                    ) : '0.00 Dr'}
                  </span>
                </div>
                <div className="panel-body-summary-row">
                  <span className="text-slate-400">Period Debit:</span>
                  <span className="text-rose-600">{formatNumber(stats.totalDebit)}</span>
                </div>
                <div className="panel-body-summary-row">
                  <span className="text-slate-400">Period Credit:</span>
                  <span className="text-emerald-600">{formatNumber(stats.totalCredit)}</span>
                </div>
                <div className="panel-body-summary-row">
                  <span className="text-slate-900">Closing Position:</span>
                  <span className="text-slate-900 font-black">
                    {formatNumber(Math.abs(stats.closing))} {stats.closing >= 0 ? 'Dr' : 'Cr'}
                  </span>
                </div>
              </div>
            </div>
          </div>

          <table className="audit-table">
            <thead>
              <tr>
                <th className="w-[80px]">Date</th>
                <th className="w-[100px]">Reference</th>
                <th>Particulars</th>
                <th className="w-[60px] right-align">Qty</th>
                <th className="w-[60px] right-align">Rate</th>
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
                    <td className="right-align font-mono">{entry.qty ? formatNumber(entry.qty) : '—'}</td>
                    <td className="right-align font-mono">{entry.rate ? formatNumber(entry.rate) : '—'}</td>
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
                <td colSpan={5} className="text-right font-black uppercase text-[7pt] px-4">Period Movement Totals:</td>
                <td className="right-align font-black border-t-2 border-black">{formatNumber(stats.totalDebit)}</td>
                <td className="right-align font-black border-t-2 border-black">{formatNumber(stats.totalCredit)}</td>
                <td className="right-align font-black border-t-2 border-black bg-slate-50">{formatNumber(Math.abs(stats.closing))}</td>
                <td className="center-align font-black border-t-2 border-black bg-slate-50">{stats.closing >= 0 ? 'Dr' : 'Cr'}</td>
              </tr>
            </tfoot>
          </table>

          {/* SIGNATURE BLOCK */}
          <div className="signature-block">
            <div className="sign-line">Prepared By</div>
            <div className="sign-line">Audited By</div>
            <div className="sign-line">Authorized Signature</div>
          </div>

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

              <div className="flex w-full sm:w-auto flex-wrap items-center gap-2">
                <Button variant="outline" className="h-10 flex-1 sm:flex-none rounded-none font-bold uppercase text-[10px] tracking-widest gap-2 border-slate-300 bg-white hover:bg-slate-900 hover:text-white transition-colors" onClick={() => window.print()} aria-label="Print ledger statement">
                  <Printer className="h-4 w-4 text-[#0f766e]" /> Print Ledger
                </Button>
                <Button variant="outline" className="h-10 flex-1 sm:flex-none rounded-none font-bold uppercase text-[10px] tracking-widest gap-2 border-slate-300 bg-white hover:bg-emerald-800 hover:text-white transition-colors text-emerald-800" onClick={() => exportToCSV(ledgerEntries)} aria-label="Export ledger CSV">
                  <Download className="h-4 w-4" /> Export CSV
                </Button>
              </div>
            </div>

            <div className="mt-6 grid grid-cols-1 lg:grid-cols-12 gap-3 items-end bg-white p-4 border border-slate-200 shadow-sm">
              <div className="lg:col-span-5 space-y-1">
                <Label className="text-[9px] font-black uppercase tracking-widest text-slate-500">Account Selection</Label>
                <Popover open={comboboxOpen} onOpenChange={setComboboxOpen}>
                  <PopoverTrigger asChild>
                    <Button variant="outline" role="combobox" aria-expanded={comboboxOpen} className={cn("w-full h-11 justify-between bg-white border-slate-300 rounded-none px-4 font-bold text-xs normal-case transition-colors focus:border-slate-900", selectedEntityId && "border-[#0f766e] text-[#0f766e] bg-[#0f766e]/5 hover:bg-[#0f766e]/10")}>
                      {selectedEntityId ? allEntities?.find((e: any) => e.id === selectedEntityId)?.name : "Search Customer or General Account..."}
                      <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50 text-slate-500" />
                    </Button>
                  </PopoverTrigger>
                  <PopoverContent className="w-[var(--radix-popover-trigger-width)] p-0 bg-white border border-slate-900 rounded-none shadow-none">
                    <div className="rounded-none">
                      <input
                        placeholder="Type to filter..."
                        className="h-11 w-full border-none border-b border-slate-200 px-4 font-bold text-xs focus:ring-0 focus:outline-none"
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

                          const customers = filtered.filter(e => e.type === 'party' && (e.originalType === 'customer' || e.originalType === 'both'));
                          const suppliers = filtered.filter(e => e.type === 'party' && (e.originalType === 'supplier' || e.originalType === 'both'));
                          const accounts = filtered.filter(e => e.type === 'account');

                          return (
                            <div className="flex flex-col divide-y divide-slate-100">
                              {/* Customers Section */}
                              {customers.length > 0 && (
                                <div className="py-1">
                                  <div className="px-4 py-1 text-[8px] font-black text-[#0f766e] bg-[#0f766e]/5 uppercase tracking-widest">
                                    Customers ({customers.length})
                                  </div>
                                  {customers.map((entity: any) => (
                                    <div
                                      key={entity.id}
                                      onClick={() => { setSelectedEntityId(entity.id); setSelectedEntityType(entity.type); setComboboxOpen(false); setComboboxFilter(''); }}
                                      className="flex justify-between items-center py-2 px-4 cursor-pointer hover:bg-slate-100"
                                    >
                                      <span className="font-bold text-slate-900 uppercase text-xs">{entity.name}</span>
                                      <span className="text-[7.5px] font-black uppercase bg-teal-50 text-teal-700 border border-teal-100 px-1 py-0.5">
                                        {entity.originalType === 'both' ? 'Both' : 'Customer'}
                                      </span>
                                    </div>
                                  ))}
                                </div>
                              )}

                              {/* Suppliers Section */}
                              {suppliers.length > 0 && (
                                <div className="py-1">
                                  <div className="px-4 py-1 text-[8px] font-black text-rose-700 bg-rose-50/30 uppercase tracking-widest">
                                    Suppliers ({suppliers.length})
                                  </div>
                                  {suppliers.map((entity: any) => (
                                    <div
                                      key={entity.id}
                                      onClick={() => { setSelectedEntityId(entity.id); setSelectedEntityType(entity.type); setComboboxOpen(false); setComboboxFilter(''); }}
                                      className="flex justify-between items-center py-2 px-4 cursor-pointer hover:bg-slate-100"
                                    >
                                      <span className="font-bold text-slate-900 uppercase text-xs">{entity.name}</span>
                                      <span className="text-[7.5px] font-black uppercase bg-rose-50 text-rose-700 border border-rose-100 px-1 py-0.5">
                                        {entity.originalType === 'both' ? 'Both' : 'Supplier'}
                                      </span>
                                    </div>
                                  ))}
                                </div>
                              )}

                              {/* Ledger Accounts Section */}
                              {accounts.length > 0 && (
                                <div className="py-1">
                                  <div className="px-4 py-1 text-[8px] font-black text-blue-700 bg-blue-50/20 uppercase tracking-widest">
                                    General Ledger Accounts ({accounts.length})
                                  </div>
                                  {accounts.map((entity: any) => (
                                    <div
                                      key={entity.id}
                                      onClick={() => { setSelectedEntityId(entity.id); setSelectedEntityType(entity.type); setComboboxOpen(false); setComboboxFilter(''); }}
                                      className="flex justify-between items-center py-2 px-4 cursor-pointer hover:bg-slate-100"
                                    >
                                      <span className="font-bold text-slate-900 uppercase text-xs">{entity.name}</span>
                                      <span className="text-[7.5px] font-black uppercase bg-blue-50 text-blue-700 border border-blue-100 px-1 py-0.5">{entity.originalType}</span>
                                    </div>
                                  ))}
                                </div>
                              )}
                            </div>
                          );
                        })()}
                      </div>
                    </div>
                  </PopoverContent>
                </Popover>
              </div>

              <div className="lg:col-span-3 space-y-1">
                <Label className="text-[9px] font-black uppercase text-slate-500 tracking-wider">Statement From</Label>
                <div className="relative">
                  <Calendar className="absolute left-3.5 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-slate-400 pointer-events-none" />
                  <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} className="w-full h-11 pl-10 pr-3 bg-white border border-slate-300 rounded-none font-bold text-xs focus:border-slate-900 outline-none transition-colors focus:ring-1 focus:ring-slate-900" />
                </div>
              </div>

              <div className="lg:col-span-3 space-y-1">
                <Label className="text-[9px] font-black uppercase text-slate-500 tracking-wider">Statement To</Label>
                <div className="relative">
                  <Calendar className="absolute left-3.5 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-slate-400 pointer-events-none" />
                  <input type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} className="w-full h-11 pl-10 pr-3 bg-white border border-slate-300 rounded-none font-bold text-xs focus:border-slate-900 outline-none transition-colors focus:ring-1 focus:ring-slate-900" />
                </div>
              </div>

              <div className="lg:col-span-1">
                <Button variant="outline" className="h-11 w-full rounded-none border-slate-300 bg-white hover:bg-rose-50 hover:text-rose-600 hover:border-rose-300 transition-colors" onClick={() => { setSelectedEntityId(''); setSelectedEntityType(''); }} aria-label="Clear ledger filters">
                  <X className="h-4 w-4" />
                </Button>
              </div>
            </div>
          </div>

          {/* MAIN CONTENT WEB VIEW */}
          <div className="px-6 space-y-8 mt-8">
            {selectedEntityId && (
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                {controlAccountKind && (
                  <div className="summary-card sm:col-span-2 lg:col-span-4 border-l-4 border-l-slate-900 bg-slate-50/50 p-4">
                    <span className="summary-label text-[8px] font-black uppercase text-slate-400 tracking-widest">Control Account View</span>
                    <span className="text-[11px] font-black uppercase text-slate-700 tracking-wider block mt-1">
                      Ledger-backed party closing balances as of {formatDate(endDate)}
                    </span>
                  </div>
                )}
                
                {/* 1. Opening Balance Card */}
                <div className="summary-card bg-white p-4 border border-slate-200 flex flex-col justify-between h-24 shadow-sm">
                  <span className="summary-label text-[8px] font-black uppercase text-slate-400 tracking-widest">Opening Balance B/F</span>
                  <div className="flex items-baseline justify-between mt-2">
                    <span className="text-lg font-black num-audit text-slate-700">{formatNumber(Math.abs(stats.opening))}</span>
                    <span className={cn("px-1.5 py-0.5 font-black text-[8px] uppercase border rounded-sm", stats.opening >= 0 ? "text-rose-700 border-rose-200 bg-rose-50/20" : "text-emerald-700 border-emerald-200 bg-emerald-50/20")}>
                      {stats.opening >= 0 ? 'Debit (Dr)' : 'Credit (Cr)'}
                    </span>
                  </div>
                </div>

                {/* 2. Period Debits (Dr) */}
                <div className="summary-card bg-white p-4 border border-slate-200 flex flex-col justify-between h-24 shadow-sm">
                  <span className="summary-label text-[8px] font-black uppercase text-slate-400 tracking-widest">Period Debits (Dr / Out)</span>
                  <div className="flex items-baseline justify-between mt-2">
                    <span className="text-lg font-black num-audit text-rose-700">{formatNumber(stats.totalDebit)}</span>
                    <span className="text-[8px] font-black text-rose-600 uppercase">Outflow</span>
                  </div>
                </div>

                {/* 3. Period Credits (Cr) */}
                <div className="summary-card bg-white p-4 border border-slate-200 flex flex-col justify-between h-24 shadow-sm">
                  <span className="summary-label text-[8px] font-black uppercase text-slate-400 tracking-widest">Period Credits (Cr / In)</span>
                  <div className="flex items-baseline justify-between mt-2">
                    <span className="text-lg font-black num-audit text-emerald-700">{formatNumber(stats.totalCredit)}</span>
                    <span className="text-[8px] font-black text-emerald-600 uppercase">Inflow</span>
                  </div>
                </div>

                {/* 4. Net Settlement Position */}
                <div className={cn("summary-card p-4 border flex flex-col justify-between h-24 transition-colors shadow-sm", stats.closing >= 0 ? "border-rose-200 bg-rose-50/10" : "border-emerald-200 bg-emerald-50/10")}>
                  <span className="summary-label text-[8px] font-black uppercase text-slate-500 tracking-widest">Net Closing Position</span>
                  <div className="flex items-baseline justify-between mt-2">
                    <span className={cn("text-xl font-black num-audit", stats.closing >= 0 ? "text-rose-700" : "text-emerald-700")}>{formatNumber(Math.abs(stats.closing))}</span>
                    <span className={cn("px-2 py-0.5 font-black text-[8px] uppercase border rounded-sm", stats.closing >= 0 ? "text-rose-800 border-rose-300 bg-rose-100" : "text-emerald-800 border-emerald-300 bg-emerald-100")}>
                      {stats.closing >= 0 ? 'Receivable (Dr)' : 'Payable (Cr)'}
                    </span>
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
                <div className="audit-table-shell">
                  <div>
                    <table className="ledger-table">
                      <thead>
                        <tr className="bg-slate-900">
                          <th className="w-28 !text-white">Date</th>
                          <th className="w-32 !text-white">Voucher No</th>
                          <th className="!text-white">Particulars / Journal Details</th>
                          <th className="right-align w-20 !text-white">Qty</th>
                          <th className="right-align w-20 !text-white">Rate</th>
                          <th className="right-align w-32 !text-white">Debit (Out)</th>
                          <th className="right-align w-32 !text-white">Credit (In)</th>
                          <th className="right-align w-40 bg-slate-950 !text-white">Balance</th>
                        </tr>
                      </thead>
                      <tbody>
                        {ledgerEntries.map((entry: any, idx: number) => {
                          const balance = entry.running_balance || 0;
                          const isOpening = entry.voucher_no === 'OPEN';
                          return (
                            <tr key={idx} className={cn(
                              "hover:bg-slate-50/80 transition-colors",
                              isOpening ? "bg-slate-100 font-bold border-y border-slate-300 text-slate-900" : (idx % 2 === 0 ? "bg-white" : "bg-slate-50/30")
                            )}>
                              <td className="num-audit font-bold">{formatDate(entry.posting_date)}</td>
                              <td className="num-audit !text-[8px] text-slate-400">{entry.voucher_no}</td>
                              <td>
                                <div className="flex flex-col">
                                  <span className={cn("font-bold text-slate-900 uppercase leading-none tracking-tight", isOpening && "text-slate-700 font-black")}>{entry.particulars.replace(/^Ref: N\/A - /, "").trim()}</span>
                                  {entry.fuel_name && <span className="text-[8px] font-black text-slate-400 uppercase mt-1">Product: {entry.fuel_name}</span>}
                                </div>
                              </td>
                              <td className="right-align num-audit font-bold text-slate-600">{entry.qty ? formatNumber(entry.qty) : '—'}</td>
                              <td className="right-align num-audit font-bold text-slate-600">{entry.rate ? formatNumber(entry.rate) : '—'}</td>
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
                      <tfoot>
                        <tr className="bg-slate-900 text-white font-black font-mono">
                          <td colSpan={5} className="px-4 py-3 text-xs uppercase text-right text-slate-300">
                            Period Movement Totals:
                          </td>
                          <td className="px-4 py-3 text-right text-xs text-rose-400">
                            {formatNumber(stats.totalDebit)}
                          </td>
                          <td className="px-4 py-3 text-right text-xs text-emerald-400">
                            {formatNumber(stats.totalCredit)}
                          </td>
                          <td className="px-4 py-3 text-right text-xs bg-slate-950 font-black">
                            <span className="text-slate-100">{formatNumber(Math.abs(stats.closing))}</span>
                            <span className={cn("ml-1.5 text-[8px] uppercase", stats.closing >= 0 ? 'text-rose-400' : 'text-emerald-400')}>
                              {stats.closing >= 0 ? 'Dr' : 'Cr'}
                            </span>
                          </td>
                        </tr>
                      </tfoot>
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
