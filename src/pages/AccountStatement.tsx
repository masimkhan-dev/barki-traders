import { useState, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { ReversalModal } from '@/components/modals/ReversalModal';
import { PHASE1_EDIT_DELETE_MESSAGE } from '@/lib/phase1-readonly';
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
  Loader2,
  FileDown,
  Share2
} from 'lucide-react';
import { toast } from 'sonner';
import { cn } from '@/lib/utils';

// ─── Constants ────────────────────────────────────────────────────────────────
const MAX_EXPORT_ROWS = 600;

// ─── Types ────────────────────────────────────────────────────────────────────
interface StatementRow {
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
}

interface ProductSummaryRow {
  fuel_name: string;
  total_qty: number;
}

// ─── Helper: CSV Export ───────────────────────────────────────────────────────
const exportToCSV = (data: StatementRow[], filename: string) => {
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

// ─── Helper: Classic Date Format (DD-MM-YY) ───────────────────────────────────
const formatClassicDate = (dateStr: string | null | undefined): string => {
  if (!dateStr) return '-';
  const d = new Date(dateStr);
  const day = String(d.getDate()).padStart(2, '0');
  const month = String(d.getMonth() + 1).padStart(2, '0');
  const year = String(d.getFullYear()).slice(-2);
  return `${day}-${month}-${year}`;
};

// ─── Helper: Validate UUID ────────────────────────────────────────────────────
const isValidUUID = (str: string | null | undefined): boolean => {
  if (!str || typeof str !== 'string') return false;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(str.trim());
};

// ─── Helper: Time suffix for unique filenames ─────────────────────────────────
const getTimeSuffix = (): string => {
  const now = new Date();
  const hh = String(now.getHours()).padStart(2, '0');
  const mm = String(now.getMinutes()).padStart(2, '0');
  const ss = String(now.getSeconds()).padStart(2, '0');
  return `${hh}${mm}${ss}`;
};

// ─── Helper: Load html2pdf from CDN (with dedup guard) ───────────────────────
let html2pdfLoadPromise: Promise<any> | null = null;

const loadHtml2Pdf = (): Promise<any> => {
  // Already loaded
  if ((window as any).html2pdf?.Worker) {
    return Promise.resolve((window as any).html2pdf);
  }
  // Already loading — return same promise, don't inject script twice
  if (html2pdfLoadPromise) return html2pdfLoadPromise;

  html2pdfLoadPromise = new Promise((resolve, reject) => {
    // Check if script tag already exists in DOM
    const existing = document.querySelector(
      'script[src*="html2pdf.bundle.min.js"]'
    );
    if (existing) {
      // Script tag exists but window.html2pdf not ready yet — poll
      const poll = setInterval(() => {
        if ((window as any).html2pdf?.Worker) {
          clearInterval(poll);
          resolve((window as any).html2pdf);
        }
      }, 100);

      // Guard: Don't hang forever if script fails silently
      setTimeout(() => {
        clearInterval(poll);
        reject(new Error('Timeout waiting for html2pdf to load'));
      }, 10000);
      return;
    }

    const script = document.createElement('script');
    script.src =
      'https://cdnjs.cloudflare.com/ajax/libs/html2pdf.js/0.10.1/html2pdf.bundle.min.js';
    script.onload = () => resolve((window as any).html2pdf);
    script.onerror = () => {
      html2pdfLoadPromise = null; // allow retry
      reject(new Error('Failed to load html2pdf'));
    };
    document.body.appendChild(script);
  });

  return html2pdfLoadPromise;
};

// ─── Types ───────────────────────────────────────────────────────────────────
interface BuildPdfResult {
  blob: Blob;
  filename: string;
}

// ─── Core: Build PDF using PRINT LAYOUT (same as browser Ctrl+P output) ──────
//
// Strategy: instead of capturing the live screen DOM (which has responsive
// layout, overflow, truncation), we build a fresh isolated HTML document
// that uses the EXACT same print CSS already defined in the component.
// This guarantees PDF == Print output, always.
//
const buildPrintLayoutHtml = (
  rows: StatementRow[],
  partyId: string,
  partyName: string,
  startDate: string,
  endDate: string,
  stats: { opening: number; totalDebit: number; totalCredit: number; balance: number },
  productSummary: ProductSummaryRow[],
  fmtNum: (n: number) => string,
  fmtDate: (s: string | null | undefined) => string
): string => {
  const drCr = (v: number) => (v >= 0 ? 'DR' : 'CR');

  const sortedRows = [...rows].sort(
    (a, b) => new Date(a.posting_date).getTime() - new Date(b.posting_date).getTime()
  );

  const tableRows = sortedRows.map((row, i) => {
    const isOpening = row.voucher_no === 'OPEN';
    const vNo = row.voucher_no.toUpperCase();
    const cleanedNote = row.particulars
      .replace(/^Ref: N\/A - /, '')
      .replace(/^Ref: N\/A/, '')
      .trim();
    let typeLabel = cleanedNote || 'Adjustment';
    if (isOpening) {
      typeLabel = 'Opening Balance';
    } else if (!cleanedNote) {
      if (vNo.startsWith('PUR')) typeLabel = 'Inventory Purchase';
      else if (row.particulars.toLowerCase().includes('bank transfer')) typeLabel = 'Bank Transfer';
      else if (row.particulars.toLowerCase().includes('payment')) typeLabel = 'Payment Received';
    }

    if (row.fuel_name && row.fuel_name !== 'N/A' && row.fuel_name.trim() !== '') {
      typeLabel =
        typeLabel === 'Inventory Purchase' || typeLabel === 'Sale' || typeLabel === 'Sales Voucher'
          ? `${typeLabel} - ${row.fuel_name}`
          : `${typeLabel} (${row.fuel_name})`;
    }

    const rowClass = [
      isOpening ? 'bg-slate-200 font-bold border-y-2 border-slate-400' : '',
      row.is_reversed_entry ? 'opacity-30 italic bg-rose-50/20' : '',
      !isOpening && !row.is_reversed_entry && vNo.startsWith('PUR') ? 'bg-blue-50' : '',
      !isOpening && !row.is_reversed_entry && vNo.startsWith('VCH') ? 'bg-orange-50' : ''
    ].join(' ');

    const balTextClass = row.running_balance > 0 ? 'text-[#be123c]' : row.running_balance < 0 ? 'text-[#15803d]' : 'text-slate-500';
    const balBgClass = row.running_balance > 0 ? 'bg-rose-50/80 border-l border-rose-200' : row.running_balance < 0 ? 'bg-emerald-50/80 border-l border-emerald-200' : 'bg-slate-50/80';

    return `
      <tr class="${rowClass}">
        <td class="center-align num-audit text-xs text-slate-600">${fmtDate(row.posting_date)}</td>
        <td class="font-mono text-[10px] text-slate-500">${row.voucher_no}</td>
        <td class="uppercase font-bold tracking-tight text-xs text-slate-900 px-4 ${row.is_reversed_entry ? 'line-through grayscale' : ''}">${typeLabel}</td>
        <td class="right-align num-audit text-slate-600 font-bold text-xs">${(row.quantity || row.qty) ? fmtNum(row.quantity || row.qty || 0) : '-'}</td>
        <td class="right-align num-audit text-slate-500 font-bold text-xs">${(row.rate) ? fmtNum(row.rate!) : '-'}</td>
        <td class="right-align num-audit font-bold text-slate-800 text-sm">${row.debit !== 0 ? fmtNum(row.debit) : '-'}</td>
        <td class="right-align num-audit font-bold text-slate-800 text-sm">${row.credit !== 0 ? fmtNum(row.credit) : '-'}</td>
        <td class="right-align num-audit font-black text-sm px-4 ${balTextClass} ${balBgClass}">
          <div style="display:flex;align-items:center;justify-content:flex-end;gap:4px;">
            <span>${row.running_balance === 0 ? '0.00' : (row.running_balance > 0 ? '+' : '-') + fmtNum(Math.abs(row.running_balance))}</span>
            ${row.running_balance !== 0 ? `<span class="text-[7px] font-black uppercase opacity-60">${drCr(row.running_balance)}</span>` : ''}
          </div>
        </td>
      </tr>`;
  }).join('');

  const productSummaryHtml = (productSummary || [])
    .map(ps => `
      <div class="ps-box">
        <span class="ps-label">${ps.fuel_name} Summary</span>
        <span class="ps-value">${fmtNum(ps.total_qty)} <span class="ps-unit">Litres</span></span>
      </div>`)
    .join('');

  return `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=1100, initial-scale=1.0"/>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Montserrat:wght@700;900&family=JetBrains+Mono:wght@400;700&display=swap');
  
  /* Reset */
  * { box-sizing: border-box; margin: 0; padding: 0; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  html, body { width: 1100px; background: white; }
  body { font-family: 'Montserrat', sans-serif; background: white; padding: 60px; }

  /* Utility Classes */
  .flex { display: flex !important; }
  .flex-col { flex-direction: column !important; }
  .justify-between { justify-content: space-between !important; }
  .items-baseline { align-items: baseline !important; }
  .text-right { text-align: right !important; }
  .text-center { text-align: center !important; }
  .uppercase { text-transform: uppercase !important; }
  .font-black { font-weight: 900 !important; }
  .font-bold { font-weight: 700 !important; }
  .font-mono { font-family: 'JetBrains Mono', monospace !important; }
  .tracking-tighter { letter-spacing: -0.05em !important; }
  .tracking-widest { letter-spacing: 0.1em !important; }
  .tracking-tight { letter-spacing: -0.025em !important; }
  .text-2xl { font-size: 24px !important; font-weight: 900 !important; }
  .text-xs { font-size: 12px !important; }
  .text-sm { font-size: 14px !important; }
  .text-[9px] { font-size: 9px !important; }
  .text-[10px] { font-size: 10px !important; }
  .text-slate-900 { color: #0f172a !important; }
  .text-slate-500 { color: #64748b !important; }
  .text-slate-600 { color: #475569 !important; }
  .text-slate-800 { color: #1e293b !important; }
  .border-b-2 { border-bottom: 2px solid #0f172a !important; }
  .mb-6 { margin-bottom: 24px !important; }
  .pb-2 { padding-bottom: 8px !important; }
  .mt-8 { margin-top: 32px !important; }
  .gap-4 { gap: 16px !important; }
  .w-full { width: 100% !important; }
  .px-4 { padding-left: 16px !important; padding-right: 16px !important; }
  .line-through { text-decoration: line-through !important; }
  .grayscale { filter: grayscale(100%) !important; }
  .opacity-30 { opacity: 0.3 !important; }
  .opacity-60 { opacity: 0.6 !important; }
  .italic { font-style: italic !important; }
  .num-audit { font-family: 'JetBrains Mono', monospace !important; }
  
  /* Print Components */
  .print-header { border-bottom: 2pt solid black; margin-bottom: 20px; }
  
  .print-summary-box {
    display: grid !important;
    grid-template-columns: repeat(4, 1fr) !important;
    border: 1.5pt solid black !important;
    margin-bottom: 20px !important;
  }
  .print-summary-item {
    border-right: 1pt solid black;
    padding: 12px 6px;
    text-align: center;
    display: flex;
    flex-direction: column;
    justify-content: center;
  }
  .print-summary-item:last-child { border-right: none; background: #000; color: #fff; }
  .ps-label, .print-summary-label { font-size: 7pt; text-transform: uppercase; font-weight: 900; color: inherit; }
  .ps-value, .print-summary-value { font-size: 11pt; font-weight: 900; font-family: 'JetBrains Mono', monospace; }
  
  .ledger-table { width: 100%; border-collapse: collapse; border: 1.2pt solid black; margin-bottom: 20px; }
  .ledger-table th { background-color: #f1f5f9; border: 1pt solid black; padding: 8px 4px; font-size: 10pt; font-weight: 900; text-transform: uppercase; text-align: left; }
  .ledger-table td { border: 0.5pt solid #ccc; padding: 6px 4px; font-size: 9.5pt; color: black; white-space: nowrap; }

  /* Product Summary Widgets */
  .ps-box { border-left: 4px solid #0f172a; background: #f8fafc; padding: 10px 16px; display: flex; flex-direction: column; min-width: 150px; }
  .ps-unit { font-size: 10px; font-weight: 400; }

  /* Highlights */
  .bg-slate-200 { background-color: #e2e8f0 !important; }
  .bg-blue-50 { background-color: #eff6ff !important; }
  .bg-orange-50 { background-color: #fff7ed !important; }
  .bg-rose-50\/20 { background-color: rgba(255, 241, 242, 0.2) !important; }
  .bg-rose-50\/80 { background-color: rgba(255, 241, 242, 0.8) !important; }
  .bg-emerald-50\/80 { background-color: rgba(236, 253, 245, 0.8) !important; }
  .bg-slate-50\/80 { background-color: rgba(248, 250, 252, 0.8) !important; }
  .border-rose-200 { border-color: #fecdd3 !important; }
  .border-emerald-200 { border-color: #a7f3d0 !important; }
  .text-[#be123c] { color: #be123c !important; }
  .text-[#15803d] { color: #15803d !important; }
  
  .footer { margin-top: 50px; text-align: center; font-size: 9px; color: #94a3b8; font-weight: 700; text-transform: uppercase; letter-spacing: 0.2em; border-top: 1pt solid #f1f5f9; padding-top: 32px; }
</style>
</head>
<body>
  <div class="print-header flex justify-between items-baseline border-b-2 pb-2 mb-6">
    <div class="flex flex-col">
      <h2 class="text-2xl uppercase tracking-tighter">Account Statement: ${partyName}</h2>
      <span class="text-[9px] font-bold text-slate-500 uppercase tracking-widest">Business ID: ${partyId.slice(0, 12)}...</span>
    </div>
    <div class="text-right">
      <span class="text-[10px] font-black text-slate-900 uppercase">Statement Period</span>
      <p class="text-xs font-bold text-slate-500">${fmtDate(startDate)} — ${fmtDate(endDate)}</p>
    </div>
  </div>

  <div class="print-summary-box">
    <div class="print-summary-item">
      <span class="print-summary-label">Opening Balance</span>
      <span class="print-summary-value">${fmtNum(Math.abs(stats.opening))} <span class="${stats.opening >= 0 ? 'text-[#be123c]' : 'text-[#15803d]'}">${drCr(stats.opening)}</span></span>
    </div>
    <div class="print-summary-item">
      <span class="print-summary-label">Total Purchases/Dr</span>
      <span class="print-summary-value">${fmtNum(stats.totalDebit)}</span>
    </div>
    <div class="print-summary-item">
      <span class="print-summary-label">Total Payments/Cr</span>
      <span class="print-summary-value">${fmtNum(stats.totalCredit)}</span>
    </div>
    <div class="print-summary-item">
      <span class="print-summary-label">Current Balance</span>
      <span class="print-summary-value">${fmtNum(Math.abs(stats.balance))} <span class="${stats.balance >= 0 ? 'text-[#be123c]' : 'text-[#15803d]'}">${drCr(stats.balance)}</span></span>
    </div>
  </div>

  <table class="ledger-table">
    <thead>
      <tr>
        <th style="width:90px;text-align:center;">Date</th>
        <th style="width:110px;">Ref/Voucher</th>
        <th style="width:280px;">Transaction Type</th>
        <th style="width:80px;text-align:right;">Qty (L)</th>
        <th style="width:80px;text-align:right;">Rate</th>
        <th style="width:110px;text-align:right;">Debit</th>
        <th style="width:110px;text-align:right;">Credit</th>
        <th style="width:130px;text-align:right;background:#f8fafc;">Balance</th>
      </tr>
    </thead>
    <tbody>
      ${tableRows}
    </tbody>
  </table>

  ${productSummaryHtml ? `<div class="mt-8 flex gap-4">${productSummaryHtml}</div>` : ''}

  <div class="footer">End of Account Statement — Thank you for your business</div>
</body>
</html>`;
};

const buildPdfFromElement = async (
  partyId: string,
  partyName: string,
  startDate: string,
  endDate: string,
  rows: StatementRow[],
  stats: { opening: number; totalDebit: number; totalCredit: number; balance: number },
  productSummary: ProductSummaryRow[],
  fmtNum: (n: number) => string,
  fmtDate: (s: string | null | undefined) => string
): Promise<BuildPdfResult> => {
  const safeName =
    partyName?.replace(/[^a-zA-Z0-9]/g, '_').replace(/_+/g, '_') || 'unknown';
  const filename = `statement_${safeName}_${startDate}_${endDate}_${getTimeSuffix()}.pdf`;

  // Build isolated print-layout HTML
  const html = buildPrintLayoutHtml(
    rows, partyId, partyName, startDate, endDate, stats, productSummary, fmtNum, fmtDate
  );

  // Inject into hidden iframe so fonts/styles render in isolation
  const iframe = document.createElement('iframe');
  // width matches body width: 1100px. height is auto to prevent clipping
  iframe.style.cssText = 'position:fixed;left:-9999px;top:0;width:1100px;height:10px;border:none;visibility:hidden;';
  document.body.appendChild(iframe);

  const iframeDoc = iframe.contentDocument!;
  iframeDoc.open();
  iframeDoc.write(html);
  iframeDoc.close();

  // Wait for fonts to load natively (with safety fallback for older browsers/Safari)
  try {
    if (iframeDoc.fonts && iframeDoc.fonts.ready) {
      await iframeDoc.fonts.ready;
    } else if ((document as any).fonts && (document as any).fonts.ready) {
      await (document as any).fonts.ready;
    }
  } catch (e) {
    console.warn('Font loading check failed, proceeding with timeout fallback');
  }
  await new Promise(resolve => setTimeout(resolve, 500));

  // Update iframe height to precisely match content avoiding truncation
  iframe.style.height = iframeDoc.body.scrollHeight + 'px';

  const options = {
    margin: [6, 6, 6, 6],
    filename,
    image: { type: 'jpeg', quality: 1 },
    html2canvas: {
      scale: 2,
      useCORS: true,
      scrollY: 0,
      scrollX: 0,
      x: 0,
      windowWidth: 1100,
      width: 1100,
    },
    jsPDF: {
      unit: 'mm',
      format: 'a4',
      orientation: 'landscape',
    },
  };

  try {
    const html2pdf = await loadHtml2Pdf();
    const blob: Blob = await html2pdf()
      .set(options)
      .from(iframeDoc.body)
      .outputPdf('blob');
    return { blob, filename };
  } finally {
    document.body.removeChild(iframe);
  }
};

// ─── Component ────────────────────────────────────────────────────────────────
export default function AccountStatement() {
  const today = new Date();
  const firstDayOfMonth = new Date(today.getFullYear(), today.getMonth(), 1);

  const [selectedParty, setSelectedParty] = useState<string>('');
  const [startDate, setStartDate] = useState<string>(
    firstDayOfMonth.toISOString().split('T')[0]
  );
  const [endDate, setEndDate] = useState<string>(
    today.toISOString().split('T')[0]
  );

  const [appliedParty, setAppliedParty] = useState<string | null>(null);
  const [appliedStart, setAppliedStart] = useState<string>(startDate);
  const [appliedEnd, setAppliedEnd] = useState<string>(endDate);

  const [revModalOpen, setRevModalOpen] = useState(false);
  const [selectedVoucher, setSelectedVoucher] = useState<string | null>(null);

  // ── FIX #10: separate loading states for each button ──────────────────────
  const [isDownloadingPdf, setIsDownloadingPdf] = useState(false);
  const [isSharingPdf, setIsSharingPdf] = useState(false);

  // ─── Queries ──────────────────────────────────────────────────────────────
  const { data: parties } = useQuery({
    queryKey: ['parties-list'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('parties')
        .select('id, name')
        .order('name');
      if (error) {
        toast.error('Failed to load parties');
        throw error;
      }
      return data;
    },
  });

  const activeParty = parties?.find(p => p.id === appliedParty);

  const handleSearch = () => {
    if (!selectedParty || !isValidUUID(selectedParty)) {
      toast.error('Please select a valid account khata');
      return;
    }
    setAppliedParty(selectedParty);
    setAppliedStart(startDate);
    setAppliedEnd(endDate);
  };

  const { data: rawStatement, isLoading } = useQuery({
    queryKey: ['party-statement-v8', appliedParty, appliedStart, appliedEnd],
    enabled:
      appliedParty !== null &&
      isValidUUID(appliedParty) &&
      !!appliedStart &&
      !!appliedEnd,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_party_statement', {
        p_party_id: appliedParty!,
        p_start_date: appliedStart,
        p_end_date: appliedEnd,
      });

      if (error) {
        console.error('RPC get_party_statement failed:', error);
        toast.error(`Failed to load statement: ${error.message || 'Unknown error'} `);
        throw new Error(error.message || 'RPC call failed');
      }

      return data as unknown as StatementRow[];
    },
  });

  const { data: productSummary } = useQuery({
    queryKey: ['party-product-summary-v8', appliedParty, appliedStart, appliedEnd],
    enabled:
      !!appliedParty &&
      isValidUUID(appliedParty) &&
      !!appliedStart &&
      !!appliedEnd,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_party_product_summary', {
        p_party_id: appliedParty!,
        p_start_date: appliedStart,
        p_end_date: appliedEnd,
      });

      if (error) {
        console.warn('Product summary failed:', error);
        return [];
      }

      return data as ProductSummaryRow[];
    },
  });

  // ─── Stats ────────────────────────────────────────────────────────────────
  const stats = useMemo(() => {
    if (!rawStatement || rawStatement.length === 0)
      return { opening: 0, balance: 0, totalDebit: 0, totalCredit: 0 };

    // Explicitly sort statement for chronological stats calculation
    const sorted = [...rawStatement].sort(
      (a, b) => new Date(a.posting_date).getTime() - new Date(b.posting_date).getTime()
    );

    const openingRow = sorted[0].voucher_no === 'OPEN' ? sorted[0] : null;
    const opening = openingRow ? openingRow.running_balance : 0;

    const transactions = sorted.filter(
      r => r.voucher_no !== 'OPEN' && !r.is_reversed_entry
    );
    const totalDebit = transactions.reduce(
      (sum, r) => sum + (Number(r.debit) || 0),
      0
    );
    const totalCredit = transactions.reduce(
      (sum, r) => sum + (Number(r.credit) || 0),
      0
    );

    const closing = sorted[sorted.length - 1];
    return {
      opening,
      totalDebit,
      totalCredit,
      balance: closing.running_balance,
    };
  }, [rawStatement]);

  // ─── Guard: check statement loaded before export ──────────────────────────
  const canExport = (): boolean => {
    if (!appliedParty || !rawStatement || rawStatement.length === 0) {
      toast.error('Please load the statement first.');
      return false;
    }
    if (rawStatement.length > MAX_EXPORT_ROWS) {
      toast.error(`Statement too large (${rawStatement.length} rows). Please reduce date range.`);
      return false;
    }
    return true;
  };

  // ─── Handler: Download PDF (Blob) ─────────────────────────────────────────
  const handleDownloadPDF = async () => {
    if (!canExport()) return;
    setIsDownloadingPdf(true);

    try {
      const { blob, filename } = await buildPdfFromElement(
        appliedParty!,
        activeParty?.name ?? '',
        appliedStart,
        appliedEnd,
        rawStatement!,
        stats,
        productSummary ?? [],
        formatNumber,
        formatClassicDate
      );

      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 3000);

      toast.success('PDF downloaded successfully.');
    } catch (error) {
      console.error(error);
      toast.error('Failed to generate PDF layout.');
    } finally {
      setIsDownloadingPdf(false);
    }
  };

  // ─── Handler: WhatsApp Share ──────────────────────────────────────────────
  const handleWhatsAppShare = async () => {
    if (!canExport()) return;
    setIsSharingPdf(true);

    try {
      const { blob, filename } = await buildPdfFromElement(
        appliedParty!,
        activeParty?.name ?? '',
        appliedStart,
        appliedEnd,
        rawStatement!,
        stats,
        productSummary ?? [],
        formatNumber,
        formatClassicDate
      );

      const summaryMsg = [
        `*Customer:* ${activeParty?.name}`,
        `*Period:* ${formatClassicDate(appliedStart)} to ${formatClassicDate(appliedEnd)}`,
        `*Opening:* ${formatNumber(Math.abs(stats.opening))} ${stats.opening >= 0 ? 'Dr' : 'Cr'}`,
        `*Total Debit:* ${formatNumber(stats.totalDebit)}`,
        `*Total Credit:* ${formatNumber(stats.totalCredit)}`,
        `*Closing:* ${formatNumber(Math.abs(stats.balance))} ${stats.balance >= 0 ? 'Dr' : 'Cr'}`,
      ].join('\n');

      const file = new File([blob], filename, { type: 'application/pdf' });

      // ── Mobile: native share with file ────────────────────────────────────
      if (
        navigator.share &&
        navigator.canShare &&
        navigator.canShare({ files: [file] })
      ) {
        await navigator.share({
          files: [file],
          title: 'Account Statement',
          text: summaryMsg,
        });
        return;
      }

      // Desktop fallback: pre-filled text share if needed, otherwise download
      const encodedMsg = encodeURIComponent(summaryMsg);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 3000);

      toast.success(
        'PDF downloaded! Redirecting to WhatsApp... attach the file to share the statement.',
        { duration: 8000 }
      );
      setTimeout(() => {
        window.open(`https://web.whatsapp.com/send?text=${encodedMsg}`, '_blank');
      }, 2000);
    } catch (error) {
      console.error(error);
      toast.error('Failed to generate PDF.');
    } finally {
      setIsSharingPdf(false);
    }
  };

  // ─── Render ───────────────────────────────────────────────────────────────
  return (
    <DashboardLayout>
      <div className="bg-white min-h-screen pb-20 print:p-0">
        <style
          dangerouslySetInnerHTML={{
            __html: `
@import url('https://fonts.googleapis.com/css2?family=Montserrat:wght@700;900&display=swap');

@media screen { .print-only { display: none !important; } }
@media print {
  @page { size: A4 landscape; margin: 10mm; }
  
  /* Reset layout - hide everything non-document via index.css */
  .print-container-base {
    display: block !important;
    position: static !important;
    width: 100% !important;
    padding: 0 !important;
    margin: 0 !important;
    background: white !important;
  }
  .ledger-pdf-container {
    width: 100% !important;
    background: white !important;
    padding: 10px !important;
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
    border: 2pt solid black !important;
    margin-bottom: 15px !important;
  }
  .print-summary-item {
    border-right: 1pt solid black !important;
    padding: 10px 5px !important;
    text-align: center;
  }
  .print-summary-item:last-child { border-right: none !important; background: #000 !important; color: #fff !important; -webkit-print-color-adjust: exact; }
  .print-summary-label {
    font-size: 8pt !important;
    text-transform: uppercase !important;
    font-weight: 900 !important;
    margin-bottom: 2px;
  }
  .print-summary-value {
    font-size: 11pt !important;
    font-weight: 900 !important;
  }
  .print-table {
    width: 100% !important;
    border-collapse: collapse !important;
    border: 1.5pt solid black !important;
  }
  .print-table tr { break-inside: avoid !important; }
  .print-table th {
    background-color: #f8fafc !important;
    border: 1pt solid black !important;
    padding: 8px 4px !important;
    font-size: 10pt !important;
    text-transform: uppercase !important;
  }
  .print-table td {
    border: 0.5pt solid #000 !important;
    padding: 6px 4px !important;
    font-size: 9.5pt !important;
  }
  .print-neg-balance { color: #15803d !important; font-weight: bold !important; }
  .print-pos-balance { color: #be123c !important; font-weight: bold !important; }
  .print-hidden, button, nav, aside, [class*="sticky-filter-bar"], .react-datepicker { display: none !important; }
  * {
    -webkit-print-color-adjust: exact !important;
    print-color-adjust: exact !important;
  }
}
          }
`,
          }}
        />

        {/* STICKY FILTER BAR */}
        <div className="sticky-filter-bar print:hidden px-4 sm:px-6">
          <div className="max-w-7xl mx-auto flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6">
            <div className="report-header mb-0">
              <h1 className="report-title">Account Register</h1>
              <p className="report-subtitle text-[10px]">
                Professional Audit Terminal v8.0
              </p>
            </div>

            <div className="flex flex-wrap items-center gap-3 bg-slate-50 p-2 border border-slate-200">
              <div className="min-w-[220px] flex flex-col">
                <label className="text-[9px] font-black uppercase text-slate-500 mb-1">
                  Account Khata
                </label>
                <Select value={selectedParty} onValueChange={setSelectedParty}>
                  <SelectTrigger className="h-9 bg-white font-bold border-slate-300 rounded-none focus:ring-0">
                    <SelectValue placeholder="Search..." />
                  </SelectTrigger>
                  <SelectContent className="rounded-none border-slate-900">
                    {parties?.map(p => (
                      <SelectItem
                        key={p.id}
                        value={p.id}
                        className="font-bold text-xs uppercase"
                      >
                        {p.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="flex flex-col">
                <label className="text-[9px] font-black uppercase text-slate-500 mb-1">
                  From
                </label>
                <input
                  type="date"
                  value={startDate}
                  onChange={e => setStartDate(e.target.value)}
                  className="h-9 px-3 border border-slate-300 rounded-none font-bold text-xs outline-none focus:border-slate-900"
                />
              </div>

              <div className="flex flex-col">
                <label className="text-[9px] font-black uppercase text-slate-500 mb-1">
                  To
                </label>
                <input
                  type="date"
                  value={endDate}
                  onChange={e => setEndDate(e.target.value)}
                  className="h-9 px-3 border border-slate-300 rounded-none font-bold text-xs outline-none focus:border-slate-900"
                />
              </div>

              <div className="flex gap-2 self-end mb-0.5">
                <Button
                  onClick={handleSearch}
                  className="h-9 bg-slate-900 hover:bg-black text-white px-6 font-black uppercase text-[10px] tracking-widest rounded-none"
                >
                  Query
                </Button>

                <Button
                  variant="outline"
                  size="icon"
                  className="h-9 w-9 rounded-none border-slate-300 bg-white"
                  onClick={() => window.print()}
                >
                  <Printer className="h-4 w-4" />
                </Button>

                <Button
                  variant="outline"
                  size="icon"
                  className="h-9 w-9 rounded-none border-slate-300 bg-white text-green-700"
                  onClick={() => {
                    if (!rawStatement || rawStatement.length === 0) {
                      toast.error('Please load the statement first.');
                      return;
                    }
                    exportToCSV(rawStatement, 'account_statement');
                  }}
                >
                  <Download className="h-4 w-4" />
                </Button>

                {/* Download PDF — only this button disables during its own operation */}
                <Button
                  variant="outline"
                  className="h-9 rounded-none border-slate-300 bg-white px-3 font-bold uppercase text-[10px] tracking-widest gap-2"
                  onClick={handleDownloadPDF}
                  disabled={isDownloadingPdf}
                >
                  {isDownloadingPdf ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <FileDown className="h-4 w-4" />
                  )}
                  Download PDF
                </Button>

                {/* WhatsApp Share — only this button disables during its own operation */}
                <Button
                  variant="outline"
                  className="h-9 rounded-none border-slate-300 bg-white px-3 font-bold uppercase text-[10px] tracking-widest gap-2 text-[#25D366]"
                  onClick={handleWhatsAppShare}
                  disabled={isSharingPdf}
                >
                  {isSharingPdf ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Share2 className="h-4 w-4" />
                  )}
                  Share to WhatsApp
                </Button>
              </div>
            </div>
          </div>

          {/* COMPACT SUMMARY STRIP */}
          <div className="max-w-7xl mx-auto mt-4 pt-4 border-t border-slate-200 flex flex-wrap items-center justify-end gap-8">
            <div className="flex flex-col items-end">
              <span className="text-[8px] font-black uppercase text-slate-400 tracking-widest">
                Opening Balance
              </span>
              <span
                className={cn(
                  'text-xs font-bold num-audit',
                  stats.opening >= 0 ? 'text-slate-900' : 'text-liabilities'
                )}
              >
                {stats.opening === 0
                  ? '0.00'
                  : `${formatNumber(Math.abs(stats.opening))} ${stats.opening >= 0 ? 'Dr' : 'Cr'} `}
              </span>
            </div>
            <div className="flex flex-col items-end border-l border-slate-200 pl-8">
              <span className="text-[8px] font-black uppercase text-slate-400 tracking-widest">
                Total Debit
              </span>
              <span className="text-xs font-bold num-audit text-assets">
                {formatNumber(stats.totalDebit)}
              </span>
            </div>
            <div className="flex flex-col items-end border-l border-slate-200 pl-8">
              <span className="text-[8px] font-black uppercase text-slate-400 tracking-widest">
                Total Credit
              </span>
              <span className="text-xs font-bold num-audit text-liabilities">
                {formatNumber(stats.totalCredit)}
              </span>
            </div>
            <div className="flex flex-col items-end bg-slate-900 px-4 py-1.5 ml-4">
              <span className="text-[8px] font-black uppercase text-slate-400 tracking-widest leading-none mb-1">
                Account Closing
              </span>
              <span className="text-sm font-black num-audit text-white leading-none">
                {stats.balance === 0
                  ? '0.00'
                  : `${formatNumber(Math.abs(stats.balance))} ${stats.balance >= 0 ? 'Dr' : 'Cr'} `}
              </span>
            </div>
          </div>
        </div>

        {/* MAIN CONTENT */}
        {isLoading ? (
          <div className="flex flex-col items-center justify-center min-h-[50vh] gap-4 opacity-50">
            <Loader2 className="h-10 w-10 animate-spin text-slate-900" />
            <span className="text-[10px] font-black uppercase tracking-[0.3em] text-slate-500">
              Retrieving Ledger Records...
            </span>
          </div>
        ) : appliedParty ? (
          <div
            id="ledger-statement-document"
            className="max-w-7xl mx-auto px-4 pt-8 pb-20 print:p-0 print-container-base ledger-pdf-container"
          >
            <div className="print-header flex justify-between items-baseline border-b-2 border-slate-900 pb-2 mb-6">
              <div className="flex flex-col">
                <h2 className="text-2xl font-black uppercase text-slate-900 tracking-tighter">
                  Account Statement: {activeParty?.name}
                </h2>
                <span className="text-[9px] font-bold text-slate-500 uppercase tracking-widest">
                  Business ID: {appliedParty.slice(0, 12)}...
                </span>
              </div>
              <div className="text-right">
                <span className="text-[10px] font-black text-slate-900 uppercase">
                  Statement Period
                </span>
                <p className="text-xs font-bold text-slate-500">
                  {formatClassicDate(appliedStart)} —{' '}
                  {formatClassicDate(appliedEnd)}
                </p>
              </div>
            </div>

            {/* QUICK SUMMARY BOX (Print Only) */}
            <div className="print-summary-box print-only">
              <div className="print-summary-item">
                <span className="print-summary-label">Opening Balance</span>
                <span className="print-summary-value">
                  {formatNumber(Math.abs(stats.opening))}
                  <span
                    className={cn(
                      'ml-1',
                      stats.opening >= 0 ? 'text-[#be123c]' : 'text-[#15803d]'
                    )}
                  >
                    {stats.opening >= 0 ? 'DR' : 'CR'}
                  </span>
                </span>
              </div>
              <div className="print-summary-item">
                <span className="print-summary-label">Total Purchases/Dr</span>
                <span className="print-summary-value">
                  {formatNumber(stats.totalDebit)}
                </span>
              </div>
              <div className="print-summary-item">
                <span className="print-summary-label">Total Payments/Cr</span>
                <span className="print-summary-value">
                  {formatNumber(stats.totalCredit)}
                </span>
              </div>
              <div className="print-summary-item">
                <span className="print-summary-label">Current Balance</span>
                <span className="print-summary-value">
                  {formatNumber(Math.abs(stats.balance))}
                  <span
                    className={cn(
                      'ml-1',
                      stats.balance >= 0 ? 'text-[#be123c]' : 'text-[#15803d]'
                    )}
                  >
                    {stats.balance >= 0 ? 'DR' : 'CR'}
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
                    <th className="right-align w-24 px-4 py-3">Qty (L)</th>
                    <th className="right-align w-24 px-4 py-3">Rate</th>
                    <th className="right-align w-32 px-4 py-3">Debit</th>
                    <th className="right-align w-32 px-4 py-3">Credit</th>
                    <th className="right-align w-40 px-4 py-3 bg-slate-100/50 print:bg-slate-50">
                      Balance
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {rawStatement?.map((row, i) => {
                    const isOpening = row.voucher_no === 'OPEN';
                    const vNo = row.voucher_no.toUpperCase();

                    const cleanedNote = row.particulars
                      .replace(/^Ref: N\/A - /, '')
                      .replace(/^Ref: N\/A/, '')
                      .trim();
                    let typeLabel = cleanedNote || 'Adjustment';

                    if (isOpening) {
                      typeLabel = 'Opening Balance';
                    } else if (!cleanedNote) {
                      if (vNo.startsWith('PUR')) typeLabel = 'Inventory Purchase';
                      else if (row.particulars.toLowerCase().includes('bank transfer'))
                        typeLabel = 'Bank Transfer';
                      else if (row.particulars.toLowerCase().includes('payment'))
                        typeLabel = 'Payment Received';
                    }

                    if (
                      row.fuel_name &&
                      row.fuel_name !== 'N/A' &&
                      row.fuel_name.trim() !== ''
                    ) {
                      typeLabel =
                        typeLabel === 'Inventory Purchase' ||
                          typeLabel === 'Sale' ||
                          typeLabel === 'Sales Voucher'
                          ? `${typeLabel} - ${row.fuel_name} `
                          : `${typeLabel} (${row.fuel_name})`;
                    }

                    return (
                      <tr
                        // FIX #9: more stable key including posting_date
                        key={`${row.voucher_no} -${row.posting_date} -${i} `}
                        className={cn(
                          'hover:bg-slate-50/50 transition-colors',
                          isOpening
                            ? 'bg-slate-200 font-bold print:bg-slate-200 border-y-2 border-slate-400'
                            : '',
                          row.is_reversed_entry
                            ? 'opacity-30 italic bg-rose-50/20'
                            : '',
                          !isOpening &&
                            !row.is_reversed_entry &&
                            vNo.startsWith('PUR')
                            ? 'bg-blue-50/30 print:bg-blue-50 border-b border-blue-100'
                            : '',
                          !isOpening &&
                            !row.is_reversed_entry &&
                            vNo.startsWith('VCH')
                            ? 'bg-orange-50/30 print:bg-orange-50 border-b border-orange-100'
                            : ''
                        )}
                      >
                        <td className="center-align num-audit text-xs text-slate-600">
                          {formatClassicDate(row.posting_date)}
                        </td>
                        <td className="font-mono text-[10px] text-slate-500 group">
                          <div className="flex items-center justify-between">
                            <span>{row.voucher_no}</span>
                            <button
                              type="button"
                              title="Reversal disabled (Phase 1)"
                              onClick={() => toast.error(PHASE1_EDIT_DELETE_MESSAGE)}
                              className="opacity-0 group-hover:opacity-100 p-0.5 text-slate-300 print:hidden"
                            >
                              <RotateCcw className="h-3 w-3" />
                            </button>
                          </div>
                        </td>
                        <td
                          className={cn(
                            'uppercase font-bold tracking-tight text-xs text-slate-900 px-4',
                            row.is_reversed_entry && 'line-through grayscale'
                          )}
                        >
                          {typeLabel}
                        </td>
                        <td className="right-align num-audit text-slate-600 font-bold text-xs">
                          {(row.quantity || row.qty || 0) > 0
                            ? formatNumber(row.quantity || row.qty || 0)
                            : '-'}
                        </td>
                        <td className="right-align num-audit text-slate-500 font-bold text-xs">
                          {(row.rate || 0) > 0 ? formatNumber(row.rate) : '-'}
                        </td>
                        <td className="right-align num-audit font-bold text-slate-800 text-sm">
                          {row.debit > 0 ? formatNumber(row.debit) : '-'}
                        </td>
                        <td className="right-align num-audit font-bold text-slate-800 text-sm">
                          {row.credit > 0 ? formatNumber(row.credit) : '-'}
                        </td>
                        <td
                          className={cn(
                            'right-align num-audit font-black text-sm px-4',
                            row.running_balance > 0
                              ? 'text-[#be123c] bg-rose-50/80 border-l border-rose-200 print:text-[#be123c] print:bg-rose-50'
                              : row.running_balance < 0
                                ? 'text-[#15803d] bg-emerald-50/80 border-l border-emerald-200 print:text-[#15803d] print:bg-emerald-50'
                                : 'text-slate-500 bg-slate-50/80'
                          )}
                        >
                          <div className="flex items-center justify-end gap-1">
                            <span>
                              {row.running_balance === 0
                                ? '0.00'
                                : `${row.running_balance > 0 ? '+' : '-'}${formatNumber(Math.abs(row.running_balance))} `}
                            </span>
                            {row.running_balance !== 0 && (
                              <span className="text-[7px] ml-1 font-black uppercase opacity-60">
                                {row.running_balance > 0 ? 'DR' : 'CR'}
                              </span>
                            )}
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>

            {/* Product Summary (screen only) */}
            <div className="mt-8 flex flex-wrap gap-4 print:hidden">
              {productSummary?.map((ps, i) => (
                <div
                  key={i}
                  className="border-l-4 border-slate-900 bg-slate-50 px-4 py-2 flex flex-col min-w-[140px]"
                >
                  <span className="text-[8px] font-black text-slate-500 uppercase tracking-widest">
                    {ps.fuel_name} Summary
                  </span>
                  <span className="num-audit text-lg font-black">
                    {formatNumber(ps.total_qty)}{' '}
                    <span className="text-[10px] font-normal">Litres</span>
                  </span>
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
            <h2 className="text-lg font-black uppercase tracking-[0.4em] text-slate-900">
              Audit Terminal Standby
            </h2>
            <p className="text-[10px] font-bold uppercase tracking-widest mt-2">
              Select khata to begin session
            </p>
          </div>
        )}
      </div>

      <ReversalModal
        isOpen={revModalOpen}
        voucherNo={selectedVoucher}
        onClose={() => setRevModalOpen(false)}
      />
    </DashboardLayout>
  );
}
