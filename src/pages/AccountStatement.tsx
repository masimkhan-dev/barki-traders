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
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog';
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
import { clientConfig } from '@/lib/client-config';


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

// ─── Helper: WhatsApp Date Format (DD-MMM-YYYY, e.g. 31-May-2026) ──────────────
const formatWhatsAppDate = (dateStr: string | null | undefined): string => {
  if (!dateStr) return '-';
  const d = new Date(dateStr);
  if (isNaN(d.getTime())) return '-';
  const day = String(d.getDate()).padStart(2, '0');
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const month = months[d.getMonth()];
  const year = d.getFullYear();
  return `${day}-${month}-${year}`;
};

// ─── Helper: WhatsApp Amount Format (Commas and 2 decimals, e.g. 6,403,525.00) ──
const formatWhatsAppAmount = (num: number): string => {
  return new Intl.NumberFormat('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  }).format(num);
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
  if ((window as any).html2pdf?.Worker) {
    return Promise.resolve((window as any).html2pdf);
  }
  if (html2pdfLoadPromise) return html2pdfLoadPromise;

  html2pdfLoadPromise = new Promise((resolve, reject) => {
    const existing = document.querySelector(
      'script[src*="html2pdf.bundle.min.js"]'
    );
    if (existing) {
      const poll = setInterval(() => {
        if ((window as any).html2pdf?.Worker) {
          clearInterval(poll);
          resolve((window as any).html2pdf);
        }
      }, 100);

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
      html2pdfLoadPromise = null;
      reject(new Error('Failed to load html2pdf'));
    };
    document.body.appendChild(script);
  });

  return html2pdfLoadPromise;
};

interface BuildPdfResult {
  blob: Blob;
  filename: string;
}

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
        <td class="center-align num-audit text-xs text-slate-600" style="white-space: nowrap;">${fmtDate(row.posting_date)}</td>
        <td class="font-mono text-[10px] text-slate-500" style="white-space: nowrap;">${row.voucher_no}</td>
        <td class="uppercase font-bold tracking-tight text-xs text-slate-900 px-4 ${row.is_reversed_entry ? 'line-through grayscale' : ''}">${typeLabel}</td>
        <td class="right-align num-audit text-slate-600 font-bold text-xs" style="white-space: nowrap;">${(row.quantity || row.qty) ? fmtNum(row.quantity || row.qty || 0) : '-'}</td>
        <td class="right-align num-audit text-slate-500 font-bold text-xs" style="white-space: nowrap;">${(row.rate) ? fmtNum(row.rate!) : '-'}</td>
        <td class="right-align num-audit font-bold text-slate-800 text-sm" style="white-space: nowrap;">${row.debit !== 0 ? fmtNum(row.debit) : '-'}</td>
        <td class="right-align num-audit font-bold text-slate-800 text-sm" style="white-space: nowrap;">${row.credit !== 0 ? fmtNum(row.credit) : '-'}</td>
        <td class="right-align num-audit font-black text-sm px-4 ${balTextClass} ${balBgClass}" style="white-space: nowrap;">
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

  const drCrCapitalized = (v: number) => (v >= 0 ? 'Dr' : 'Cr');

  return `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=1100, initial-scale=1.0"/>
</head>
<body>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;700;900&family=Montserrat:wght@700;900&family=JetBrains+Mono:wght@400;700&display=swap');
  
  /* Reset */
  * { box-sizing: border-box; margin: 0; padding: 0; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  html, body { width: 1100px; background: white; }
  body { font-family: 'Inter', sans-serif; background: white; padding: 20px 30px; }
  h1, h2, h3, .brand-badge { font-family: 'Montserrat', sans-serif; }

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
  .right-align { text-align: right !important; }
  .center-align { text-align: center !important; }
  
  /* Print Components */
  .brand-container { display: flex; align-items: center; gap: 12px; }
  .brand-badge { background-color: #0f766e; color: white; padding: 6px 12px; font-size: 18px; font-weight: 900; letter-spacing: 0.05em; font-family: 'Montserrat', sans-serif; }
  .brand-details { display: flex; flex-direction: column; }
  .brand-name { font-size: 20px; font-weight: 900; letter-spacing: -0.04em; color: #0f172a; text-transform: uppercase; line-height: 1; }
  .brand-tagline { font-size: 8px; font-weight: 700; color: #0f766e; text-transform: uppercase; letter-spacing: 0.12em; margin-top: 4px; }
  
  .contact-details { text-align: right; font-size: 9px; color: #475569; font-weight: 700; line-height: 1.5; font-family: 'JetBrains Mono', monospace; }
  
  .panels-row { display: flex; justify-content: space-between; gap: 15px; margin-bottom: 15px; }
  .panel-box { flex: 1; border: 1px solid #e2e8f0; page-break-inside: avoid; }
  .panel-header { background-color: #0f766e; color: white; padding: 4px 12px; font-size: 9.5px; font-weight: 900; text-transform: uppercase; letter-spacing: 0.05em; }
  .panel-body { padding: 8px 10px; font-size: 10px; color: #1e293b; line-height: 1.4; }
  .panel-body-summary-row { display: flex; justify-content: space-between; padding: 1px 0; border-bottom: 1px dashed #e2e8f0; font-family: 'JetBrains Mono', monospace; font-weight: 700; }
  .panel-body-summary-row:last-child { border-bottom: none; font-weight: 900; font-size: 11px; border-top: 1px solid #0f172a; margin-top: 3px; padding-top: 4px; }
  
  .ledger-table { width: 100%; border-collapse: collapse; border: 1.2pt solid black; margin-bottom: 15px; }
  .ledger-table th { background-color: #0f766e; border: 1pt solid black; padding: 5px 4px; font-size: 9px; font-weight: 900; text-transform: uppercase; text-align: left; }
  .ledger-table td { border: 0.5pt solid #cbd5e1; padding: 3px 4px; font-size: 9px; color: black; line-height: 1.1; word-break: break-word; }

  /* Product Summary Widgets */
  .ps-box { border-left: 4px solid #0f766e; background: #f8fafc; padding: 6px 12px; display: flex; flex-direction: column; min-width: 150px; }
  .ps-unit { font-size: 9px; font-weight: 400; }

  /* Highlights */
  .bg-slate-200 { background-color: #e2e8f0 !important; }
  .bg-blue-50 { background-color: #eff6ff !important; }
  .bg-orange-50 { background-color: #fff7ed !important; }
  .bg-rose-50\\/20 { background-color: rgba(255, 241, 242, 0.2) !important; }
  .bg-rose-50\\/80 { background-color: rgba(255, 241, 242, 0.8) !important; }
  .bg-emerald-50\\/80 { background-color: rgba(236, 253, 245, 0.8) !important; }
  .bg-slate-50\\/80 { background-color: rgba(248, 250, 252, 0.8) !important; }
  .border-rose-200 { border-color: #fecdd3 !important; }
  .border-emerald-200 { border-color: #a7f3d0 !important; }
  .text-[#be123c] { color: #be123c !important; }
  .text-[#15803d] { color: #15803d !important; }
  
  .footer { margin-top: 48px; text-align: center; font-size: 10px; color: #64748b; font-weight: 700; border-top: 1px solid #f1f5f9; padding-top: 32px; line-height: 1.4; page-break-inside: avoid; }
  tr { page-break-inside: avoid; }
  .footer-balance-note { color: #94a3b8; font-size: 10px; text-transform: uppercase; margin-bottom: 4px; }
  .footer-thankyou { font-size: 14px; font-weight: 900; color: #1e293b; text-transform: uppercase; letter-spacing: 0.1em; margin: 8px 0; }
  .developer-credit { margin-top: 12px; padding-top: 12px; border-top: 1px dashed #e2e8f0; font-family: 'JetBrains Mono', monospace; font-size: 8px; color: #94a3b8; line-height: 1.45; }
</style>
  <div class="flex justify-between items-stretch gap-4" style="margin-bottom: 15px; width: 100%;">
    <!-- Column 1: Brand / Company Info -->
    <div class="flex flex-col justify-between" style="flex: 1.2; min-width: 280px;">
      <div>
        <div class="brand-container">
          <div class="brand-badge">BKI</div>
          <div class="brand-details">
            <h1 class="brand-name">Barki Traders</h1>
            <p class="brand-tagline">${clientConfig.BUSINESS_TAGLINE}</p>
          </div>
        </div>
        <h2 style="font-size: 14px; font-weight: 900; color: #0f766e; text-transform: uppercase; letter-spacing: 0.05em; margin-top: 8px; margin-bottom: 2px;">Account Statement</h2>
      </div>
      <div style="font-size: 8.5px; color: #64748b; font-family: 'JetBrains Mono', monospace; line-height: 1.4; font-weight: 700;">
        <p>${clientConfig.BUSINESS_ADDRESS}</p>
        <p style="margin-top: 2px;">${clientConfig.BUSINESS_PHONE}</p>
        <p style="margin-top: 2px;">Email: ${clientConfig.BUSINESS_EMAIL}</p>
      </div>
    </div>

    <!-- Column 2: Bill To & Period Info -->
    <div style="flex: 1.3; min-width: 290px; border: 1px solid #e2e8f0; display: flex; flex-direction: column;">
      <div style="background-color: #0f766e; color: white; padding: 4px 12px; font-size: 9.5px; font-weight: 900; text-transform: uppercase; letter-spacing: 0.05em;">Bill To:</div>
      <div style="padding: 12px; font-size: 9.5px; line-height: 1.4; display: flex; flex-direction: column; justify-content: space-between; flex: 1;">
        <div>
          <p style="font-weight: 900; font-size: 14px; text-transform: uppercase; color: #0f172a; margin-bottom: 2px;">${partyName}</p>
          <p style="color: #94a3b8; font-size: 9.5px; font-family: 'JetBrains Mono', monospace; font-weight: 700;">CUSTOMER ID: ${partyId.slice(0, 8).toUpperCase()}</p>
        </div>
        <div style="margin-top: 16px; font-size: 9px; font-family: 'JetBrains Mono', monospace; font-weight: 700; color: #64748b; border-top: 1px dashed #e2e8f0; padding-top: 8px;">
          <p>DATE: ${new Date().toLocaleDateString('en-GB')} | PAGE: 1 of 1</p>
          <p style="margin-top: 2px;">PERIOD: ${fmtDate(startDate)} — ${fmtDate(endDate)}</p>
        </div>
      </div>
    </div>

    <!-- Column 3: Account Summary -->
    <div style="flex: 1.5; min-width: 320px; border: 1px solid #e2e8f0; display: flex; flex-direction: column;">
      <div style="background-color: #0f766e; color: white; padding: 4px 12px; font-size: 9.5px; font-weight: 900; text-transform: uppercase; letter-spacing: 0.05em;">Account Summary:</div>
      <div style="padding: 12px; font-size: 9px; display: flex; flex-direction: column; justify-content: space-between; flex: 1; font-family: 'JetBrains Mono', monospace; font-weight: 700; gap: 4px;">
        <div style="display: flex; justify-content: space-between; border-bottom: 1px dashed #f1f5f9; padding-bottom: 4px;">
          <span style="color: #64748b;">Opening Balance:</span>
          <span style="color: #0f172a;">${fmtNum(Math.abs(stats.opening))} ${drCrCapitalized(stats.opening)}</span>
        </div>
        <div style="display: flex; justify-content: space-between; border-bottom: 1px dashed #f1f5f9; padding: 2px 0;">
          <span style="color: #64748b;">Total Purchases/Dr:</span>
          <span style="color: #e11d48;">${fmtNum(stats.totalDebit)}</span>
        </div>
        <div style="display: flex; justify-content: space-between; border-bottom: 1px dashed #f1f5f9; padding: 2px 0;">
          <span style="color: #64748b;">Total Payments/Cr:</span>
          <span style="color: #059669;">${fmtNum(stats.totalCredit)}</span>
        </div>
        <div style="display: flex; justify-content: space-between; font-weight: 950; font-size: 10px; border-top: 1px solid #0f172a; margin-top: 4px; padding-top: 4px; color: #020617;">
          <span>TOTAL BALANCE DUE:</span>
          <span>${fmtNum(Math.abs(stats.balance))} ${drCr(stats.balance)}</span>
        </div>
      </div>
    </div>
  </div>

  <table class="ledger-table">
    <thead>
      <tr style="background-color: #0f766e; color: white;">
        <th style="width:90px;text-align:center;background-color: #0f766e !important;color:white !important;">Date</th>
        <th style="width:110px;background-color: #0f766e !important;color:white !important;">Ref/Voucher</th>
        <th style="width:280px;background-color: #0f766e !important;color:white !important;">Transaction Type</th>
        <th style="width:80px;text-align:right;background-color: #0f766e !important;color:white !important;">Qty (L)</th>
        <th style="width:80px;text-align:right;background-color: #0f766e !important;color:white !important;">Rate</th>
        <th style="width:110px;text-align:right;background-color: #0f766e !important;color:white !important;">Debit</th>
        <th style="width:110px;text-align:right;background-color: #0f766e !important;color:white !important;">Credit</th>
        <th style="width:130px;text-align:right;background-color: #0f766e !important;color:white !important;">Balance</th>
      </tr>
    </thead>
    <tbody>
      ${tableRows}
    </tbody>
    <tfoot>
      <tr style="background-color: #0f766e; color: white; font-weight: 900; font-family: 'JetBrains Mono', monospace; -webkit-print-color-adjust: exact; print-color-adjust: exact;">
        <td colspan="5" style="border: 1pt solid #0f766e; padding: 5px 8px; text-transform: uppercase; font-size: 9.5px; background-color: #0f766e !important; color: white !important;">Account Current Balance</td>
        <td colspan="3" style="border: 1pt solid #0f766e; padding: 5px 8px; text-align: right; font-size: 10px; background-color: #0f766e !important; color: white !important;">
          PKR ${fmtNum(Math.abs(stats.balance))} ${drCr(stats.balance)}
        </td>
      </tr>
    </tfoot>
  </table>

  ${productSummaryHtml ? `<div class="mt-8 flex gap-4">${productSummaryHtml}</div>` : ''}

  <div class="footer">
    <p class="footer-balance-note">Your account balance is PKR ${fmtNum(Math.abs(stats.balance))} ${drCr(stats.balance)}. Please keep your account current.</p>
    <p class="footer-thankyou">Thank you for your business!</p>
    <div class="developer-credit">
      <p>Software Developed by Nexly</p>
      <p style="margin-top: 2px;">Muhammad Asim Khan | 03249386812</p>
      <p style="margin-top: 2px;">nexly.biz@gmail.com</p>
    </div>
  </div>
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

  const html = buildPrintLayoutHtml(
    rows, partyId, partyName, startDate, endDate, stats, productSummary, fmtNum, fmtDate
  );

  // Keep iframe in viewport (left:0, top:0) but fully invisible and non-interactive.
  // Using left:-9999px with a wide iframe causes a horizontal scroll flash on some browsers.
  const prevOverflow = document.documentElement.style.overflow;
  document.documentElement.style.overflow = 'hidden';

  const iframe = document.createElement('iframe');
  iframe.style.cssText =
    'position:fixed;left:0;top:0;width:1100px;height:10px;border:none;' +
    'opacity:0;pointer-events:none;z-index:-9999;';
  document.body.appendChild(iframe);

  const iframeDoc = iframe.contentDocument!;
  iframeDoc.open();
  iframeDoc.write(html);
  iframeDoc.close();

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
    // Restore overflow so the page layout is never permanently affected
    document.documentElement.style.overflow = prevOverflow;
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

  const [showDirectPdfNotice, setShowDirectPdfNotice] = useState(false);

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

  const handleDownloadPDFClick = async () => {
    if (!canExport() || !appliedParty || !activeParty) return;

    const toastId = toast.loading('Generating PDF statement...');
    try {
      const { blob, filename } = await buildPdfFromElement(
        appliedParty,
        activeParty.name,
        appliedStart,
        appliedEnd,
        rawStatement || [],
        stats,
        productSummary || [],
        formatNumber,
        formatClassicDate
      );

      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = filename;
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      URL.revokeObjectURL(url);

      toast.success('PDF statement downloaded successfully!', { id: toastId });
    } catch (error: any) {
      console.error('PDF generation error:', error);
      toast.error(`Failed to generate PDF: ${error.message || 'Unknown error'}`, { id: toastId });
    }
  };

  const handleWhatsAppShareClick = async () => {
    if (!canExport() || !appliedParty || !activeParty) return;

    const toastId = toast.loading('Preparing statement for WhatsApp...');
    try {
      const { blob, filename } = await buildPdfFromElement(
        appliedParty,
        activeParty.name,
        appliedStart,
        appliedEnd,
        rawStatement || [],
        stats,
        productSummary || [],
        formatNumber,
        formatClassicDate
      );

      // Create a File object from the blob so it can be shared via Web Share API
      const file = new File([blob], filename, { type: 'application/pdf' });

      // Determine DR/CR indicator for balances
      const drCr = (v: number) => (v >= 0 ? 'DR' : 'CR');

      // Construct a professional text summary for WhatsApp message exactly as requested
      const messageText =
        `BARKI TRADERS\n` +
        `-------------------------------------------\n` +
        `Party or account: ${activeParty.name}\n` +
        `Period: ${formatWhatsAppDate(appliedStart)} to ${formatWhatsAppDate(appliedEnd)}\n` +
        `-------------------------------------------\n` +
        `Opening Balance: PKR ${formatWhatsAppAmount(Math.abs(stats.opening))} ${drCr(stats.opening)}\n` +
        `Total Debits:  PKR ${formatWhatsAppAmount(stats.totalDebit)}\n` +
        `Total Credits: PKR ${formatWhatsAppAmount(stats.totalCredit)}\n` +
        `-------------------------------------------\n` +
        `Outstanding: PKR ${formatWhatsAppAmount(Math.abs(stats.balance))} ${drCr(stats.balance)}\n` +
        `-------------------------------------------\n` +
        `Thank you for your business.  \n` +
        `This is a computer-generated statement`;

      // Check if browser supports sharing files natively (e.g., mobile devices)
      if (navigator.canShare && navigator.canShare({ files: [file] })) {
        await navigator.share({
          files: [file],
          title: `Account Statement - ${activeParty.name}`,
          text: messageText,
        });
        toast.success('Share prompt opened successfully!', { id: toastId });
      } else {
        // Fallback for desktops / browsers that don't support file sharing
        // 1. Download the PDF file automatically so they have it
        const url = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = url;
        link.download = filename;
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(url);

        // 2. Open WhatsApp Web / Mobile with the pre-filled text summary
        // They can easily paste/drag-and-drop the downloaded PDF file into the WhatsApp chat
        const whatsappUrl = `https://api.whatsapp.com/send?text=${encodeURIComponent(messageText)}`;
        window.open(whatsappUrl, '_blank');

        toast.success('PDF downloaded. WhatsApp opened with statement summary!', { id: toastId });
      }
    } catch (error: any) {
      console.error('WhatsApp share error:', error);
      toast.error(`Failed to share statement: ${error.message || 'Unknown error'}`, { id: toastId });
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

@media screen { 
  .print-only { display: none !important; } 
  .ledger-table th {
    padding: 6px 10px !important;
    font-size: 11px !important;
  }
  .ledger-table td {
    padding: 5px 10px !important;
    font-size: 11px !important;
  }
}
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
    font-size: 10px !important;
    color: #1e293b !important;
    line-height: 1.4 !important;
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
    font-size: 11px !important;
    border-top: 1px solid #0f172a !important;
    margin-top: 3px !important;
    padding-top: 4px !important;
  }
  .print-table {
    width: 100% !important;
    border-collapse: collapse !important;
    border: 1.2pt solid black !important;
  }
  .print-table tr { break-inside: avoid !important; }
  .print-table th {
    background-color: #0f766e !important;
    color: white !important;
    border: 1pt solid black !important;
    padding: 5px 4px !important;
    font-size: 9px !important;
    font-weight: 900 !important;
    text-transform: uppercase !important;
  }
  .print-table td {
    border: 0.5pt solid #cbd5e1 !important;
    padding: 3px 4px !important;
    font-size: 9px !important;
    line-height: 1.1 !important;
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
          <div className="max-w-full mx-auto flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6">
            <div className="report-header mb-0">
              <h1 className="report-title">Party Statement</h1>
              <p className="report-subtitle text-[10px]">
                Ledger-backed customer and supplier account statement
              </p>
            </div>

            <div className="flex flex-wrap items-center gap-3 bg-slate-50 p-2 border border-slate-200">
              <div className="min-w-[220px] flex flex-col">
                <label className="text-[9px] font-black uppercase text-slate-500 mb-1">
                  Select Party
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
                  Generate
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

                {/* Download PDF */}
                <Button
                  variant="outline"
                  className="h-9 rounded-none border-slate-300 bg-white px-3 font-bold uppercase text-[10px] tracking-widest gap-2"
                  onClick={handleDownloadPDFClick}
                >
                  <FileDown className="h-4 w-4" />
                  Download PDF
                </Button>

                {/* WhatsApp Share */}
                <Button
                  variant="outline"
                  className="h-9 rounded-none border-slate-300 bg-white px-3 font-bold uppercase text-[10px] tracking-widest gap-2 text-[#25D366]"
                  onClick={handleWhatsAppShareClick}
                >
                  <Share2 className="h-4 w-4" />
                  Share to WhatsApp
                </Button>
              </div>
            </div>
          </div>

          {/* COMPACT SUMMARY STRIP */}
          <div className="max-w-full mx-auto mt-4 pt-4 border-t border-slate-200 flex flex-wrap items-center justify-end gap-8">
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
            className="max-w-full mx-auto px-4 pt-8 pb-20 print:p-0 print-container-base ledger-pdf-container"
          >
            {/* SINGLE-ROW COMPACT HEADER: Brand, Bill To & Account Summary Side-by-Side */}
            <div className="flex flex-col lg:flex-row justify-between items-stretch gap-4 mb-4 print:flex-row w-full">
              {/* Column 1: Brand / Company Info */}
              <div className="flex flex-col justify-between" style={{ flex: 1.2, minWidth: '280px' }}>
                <div>
                  <div className="brand-container flex items-center gap-3">
                    <div className="brand-badge bg-[#0f766e] text-white px-3 py-1.5 font-black text-lg tracking-wider">
                      BKI
                    </div>
                    <div className="brand-details flex flex-col">
                      <h1 className="brand-name text-xl font-black uppercase text-slate-900 tracking-tight leading-none">
                        Barki Traders
                      </h1>
                      <p className="brand-tagline text-[8px] font-bold text-[#0f766e] uppercase tracking-widest mt-1">
                        {clientConfig.BUSINESS_TAGLINE}
                      </p>
                    </div>
                  </div>
                  <h2 className="text-sm font-black text-[#0f766e] uppercase tracking-wider mt-2 mb-1">Account Statement</h2>
                </div>
                <div className="text-[8.5px] text-slate-500 font-mono font-bold leading-normal">
                  <p>{clientConfig.BUSINESS_ADDRESS}</p>
                  <p className="mt-0.5">{clientConfig.BUSINESS_PHONE}</p>
                  <p className="mt-0.5">Email: {clientConfig.BUSINESS_EMAIL}</p>
                </div>
              </div>

              {/* Column 2: Bill To & Period Info */}
              <div className="flex-1 min-w-[290px] border border-slate-200 flex flex-col">
                <div className="bg-[#0f766e] text-white px-3 py-1 text-[9.5px] font-black uppercase tracking-wider">
                  Bill To:
                </div>
                <div className="p-3 flex flex-col justify-between flex-1">
                  <div>
                    <h3 className="text-sm font-black text-slate-900 uppercase mb-0.5">
                      {activeParty?.name}
                    </h3>
                    <p className="text-[9.5px] text-slate-400 font-mono font-bold">
                      CUSTOMER ID: {appliedParty?.slice(0, 8).toUpperCase()}
                    </p>
                  </div>
                  <div className="mt-4 text-[9px] font-mono font-bold text-slate-500 border-t border-dashed border-slate-200 pt-2">
                    <p>DATE: {new Date().toLocaleDateString('en-GB')} | PAGE: 1 of 1</p>
                    <p className="mt-0.5">PERIOD: {formatClassicDate(appliedStart)} — {formatClassicDate(appliedEnd)}</p>
                  </div>
                </div>
              </div>

              {/* Column 3: Account Summary */}
              <div className="flex-1 min-w-[320px] border border-slate-200 flex flex-col">
                <div className="bg-[#0f766e] text-white px-3 py-1 text-[9.5px] font-black uppercase tracking-wider">
                  Account Summary:
                </div>
                <div className="p-3 text-[9px] font-mono font-bold flex flex-col justify-between flex-1 gap-1">
                  <div className="flex justify-between border-b border-dashed border-slate-100 pb-1">
                    <span className="text-slate-500">Opening Balance:</span>
                    <span className="text-slate-900">
                      {formatNumber(Math.abs(stats.opening))} {stats.opening >= 0 ? 'Dr' : 'Cr'}
                    </span>
                  </div>
                  <div className="flex justify-between border-b border-dashed border-slate-100 py-0.5">
                    <span className="text-slate-500">Total Purchases/Dr:</span>
                    <span className="text-rose-600">{formatNumber(stats.totalDebit)}</span>
                  </div>
                  <div className="flex justify-between border-b border-dashed border-slate-100 py-0.5">
                    <span className="text-slate-500">Total Payments/Cr:</span>
                    <span className="text-emerald-600">{formatNumber(stats.totalCredit)}</span>
                  </div>
                  <div className="flex justify-between pt-1 border-t border-slate-950 font-black text-[10px] text-slate-950 mt-1">
                    <span>TOTAL BALANCE DUE:</span>
                    <span>
                      {formatNumber(Math.abs(stats.balance))} {stats.balance >= 0 ? 'DR' : 'CR'}
                    </span>
                  </div>
                </div>
              </div>
            </div>

            <div className="overflow-x-auto">
              <table className="ledger-table print-table w-full">
                <thead>
                  <tr>
                    <th className="w-24 px-4 py-1.5">Date</th>
                    <th className="w-28 px-4 py-1.5">Ref/Voucher</th>
                    <th className="px-4 py-1.5">Transaction Type</th>
                    <th className="right-align w-24 px-4 py-1.5">Qty (L)</th>
                    <th className="right-align w-24 px-4 py-1.5">Rate</th>
                    <th className="right-align w-32 px-4 py-1.5">Debit</th>
                    <th className="right-align w-32 px-4 py-1.5">Credit</th>
                    <th className="right-align w-40 px-4 py-1.5 bg-slate-100/50 print:bg-slate-50">
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
                <tfoot>
                  <tr className="bg-[#0f766e] text-white font-black font-mono print:bg-[#0f766e] print:text-white print:border-t-2 print:border-black">
                    <td colSpan={5} className="px-4 py-3 text-sm uppercase">
                      Account Current Balance
                    </td>
                    <td colSpan={3} className="px-4 py-3 text-right text-base">
                      PKR {formatNumber(Math.abs(stats.balance))} {stats.balance >= 0 ? 'DR' : 'CR'}
                    </td>
                  </tr>
                </tfoot>
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

            <div className="mt-12 text-center text-[10px] text-slate-500 font-bold uppercase tracking-wide pt-8 border-t border-slate-100 print:mt-8">
              <p className="mb-1 text-slate-400">Your account balance is PKR {formatNumber(Math.abs(stats.balance))} {stats.balance >= 0 ? 'DR' : 'CR'}. Please keep your account current.</p>
              <p className="text-sm font-black text-slate-800 uppercase tracking-widest my-2">Thank you for your business!</p>
              <div className="mt-3 pt-3 border-t border-dashed border-slate-200 text-[8px] text-slate-400 font-mono leading-normal normal-case tracking-normal">
                <p>Software Developed by Nexly</p>
                <p className="mt-0.5">Muhammad Asim Khan | 03249386812</p>
                <p className="mt-0.5">nexly.biz@gmail.com</p>
              </div>
            </div>
          </div>
        ) : (
          <div className="max-w-full mx-auto px-4 py-40 flex flex-col items-center justify-center opacity-20">
            <ShieldCheck className="h-20 w-20 text-slate-900 mb-6" />
            <h2 className="text-lg font-black uppercase tracking-[0.4em] text-slate-900">
              Account Statement Standby
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

      <AlertDialog open={showDirectPdfNotice} onOpenChange={setShowDirectPdfNotice}>
        <AlertDialogContent className="max-w-md rounded-none border border-slate-900 bg-white">
          <AlertDialogHeader>
            <AlertDialogTitle className="text-sm font-black uppercase tracking-wider text-slate-900">
              Direct Export Notice
            </AlertDialogTitle>
            <AlertDialogDescription className="text-slate-600 text-xs leading-relaxed space-y-3 pt-2">
              <p>
                Direct PDF download and WhatsApp sharing are currently under maintenance.
              </p>
              <p className="font-bold text-slate-900 border-l-2 border-[#0f766e] pl-2 bg-[#0f766e]/5 py-2">
                For a 100% correct landscape layout, please use the <span className="underline font-bold text-[#0f766e]">Print (Printer icon)</span> option and choose <span className="underline font-bold text-[#0f766e]">Save as PDF</span> in the destination settings.
              </p>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter className="mt-4 sm:justify-end">
            <AlertDialogAction
              onClick={() => setShowDirectPdfNotice(false)}
              className="rounded-none bg-[#0f766e] hover:bg-[#0f766e]/90 text-white text-[10px] font-black uppercase tracking-widest h-9 px-6"
            >
              Okay, Got it
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </DashboardLayout>
  );
}
