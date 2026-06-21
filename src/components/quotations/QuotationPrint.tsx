import { clientConfig } from '@/lib/client-config';
import { formatNumber } from '@/lib/format';

export interface QuotationItem {
  id: string;
  fuelType: string;
  quantity: number;
  rate: number;
}

interface QuotationPrintProps {
  estimateNo: string;
  estimateDate: string;
  validUntil: string;
  customerName: string;
  customerMobile: string;
  items: QuotationItem[];
  notes: string;
  grandTotal: number;
}

const formatDisplayDate = (date: string) => {
  if (!date) return '-';
  const parsedDate = new Date(`${date}T00:00:00`);
  if (Number.isNaN(parsedDate.getTime())) return '-';

  return new Intl.DateTimeFormat(clientConfig.LOCALE, {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  }).format(parsedDate);
};

const formatEstimateCurrency = (amount: number) => `Rs ${formatNumber(amount)}`;

export function QuotationPrint({
  estimateNo,
  estimateDate,
  validUntil,
  customerName,
  customerMobile,
  items,
  notes,
  grandTotal,
}: QuotationPrintProps) {
  return (
    <section className="quotation-print-page bg-white text-slate-950 border border-slate-200 p-5 sm:p-6 max-w-4xl mx-auto shadow-sm">
      <div className="print-avoid-break border-b-2 border-[#0f766e] pb-4">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div className="flex items-start gap-3">
            <div className="flex h-12 w-12 shrink-0 items-center justify-center bg-[#0f766e] text-lg font-black tracking-wider text-white">
              BKI
            </div>
            <div>
              <h1 className="text-2xl sm:text-3xl font-black uppercase tracking-tight leading-none text-slate-950">
                {clientConfig.BUSINESS_NAME}
              </h1>
              <p className="text-[10px] font-black uppercase tracking-[0.2em] text-[#0f766e] mt-1">
                {clientConfig.BUSINESS_TAGLINE}
              </p>
              <div className="mt-2 space-y-0.5 text-[10px] font-bold leading-4 text-slate-600">
                <p>{clientConfig.BUSINESS_ADDRESS}</p>
                <p>{clientConfig.BUSINESS_PHONE}</p>
                <p>Email: {clientConfig.BUSINESS_EMAIL}</p>
              </div>
            </div>
          </div>

          <div className="min-w-[190px] border border-slate-200 bg-slate-50 p-3 text-left sm:text-right">
            <span className="inline-flex bg-[#0f766e] px-2.5 py-1 text-[9px] font-black uppercase tracking-widest text-white">
              Status: Estimate
            </span>
            <div className="mt-2 grid gap-1 text-[11px] font-bold text-slate-700">
              <p><span className="text-slate-500">Estimate No:</span> {estimateNo}</p>
              <p><span className="text-slate-500">Date:</span> {formatDisplayDate(estimateDate)}</p>
              <p><span className="text-slate-500">Valid Until:</span> {formatDisplayDate(validUntil)}</p>
            </div>
          </div>
        </div>
      </div>

      <div className="print-avoid-break py-4 border-b border-slate-200">
        <div className="bg-[#0f766e] px-3 py-1.5 text-[10px] font-black uppercase tracking-widest text-white">
          Quotation / Estimate
        </div>
        <div className="grid gap-3 border-x border-b border-slate-200 p-3 sm:grid-cols-2">
          <div>
            <p className="text-[9px] font-black uppercase tracking-widest text-slate-500">Customer Name</p>
            <p className="mt-1 min-h-5 text-sm font-black">{customerName.trim() || 'Walk-in Customer'}</p>
          </div>
          <div>
            <p className="text-[9px] font-black uppercase tracking-widest text-slate-500">Mobile Number</p>
            <p className="mt-1 min-h-5 text-sm font-bold">{customerMobile.trim() || '-'}</p>
          </div>
        </div>
      </div>

      <div className="print-avoid-break py-4 overflow-x-auto">
        <div className="bg-[#0f766e] px-3 py-1.5 text-[10px] font-black uppercase tracking-widest text-white">
          Item Details
        </div>
        <table className="w-full min-w-[560px] border-collapse border border-slate-200 text-xs sm:text-sm">
          <thead>
            <tr className="bg-slate-100 text-slate-700">
              <th className="py-2 px-3 text-left text-[10px] font-black uppercase tracking-widest">Fuel Type</th>
              <th className="py-2 px-3 text-right text-[10px] font-black uppercase tracking-widest">Qty (Ltr)</th>
              <th className="py-2 px-3 text-right text-[10px] font-black uppercase tracking-widest">Rate / Ltr</th>
              <th className="py-2 px-3 text-right text-[10px] font-black uppercase tracking-widest">Amount</th>
            </tr>
          </thead>
          <tbody>
            {items.map(item => (
              <tr key={item.id} className="border-b border-slate-200">
                <td className="py-2 px-3 font-bold">{item.fuelType.trim()}</td>
                <td className="py-2 px-3 text-right font-bold">{formatNumber(item.quantity)}</td>
                <td className="py-2 px-3 text-right font-bold">{formatEstimateCurrency(item.rate)}</td>
                <td className="py-2 px-3 text-right font-black">{formatEstimateCurrency(item.quantity * item.rate)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="print-avoid-break flex justify-end border-t border-slate-200 pt-3">
        <div className="w-full max-w-sm border border-slate-200 bg-slate-50">
          <div className="bg-[#0f766e] px-3 py-1.5 text-[10px] font-black uppercase tracking-widest text-white">
            Total Summary
          </div>
          <div className="p-3">
          <div className="flex items-center justify-between gap-4">
            <span className="text-xs font-black uppercase tracking-widest">Grand Total</span>
            <span className="text-2xl font-black text-[#0f766e]">{formatEstimateCurrency(grandTotal)}</span>
          </div>
          </div>
        </div>
      </div>

      {notes.trim() && (
        <div className="print-avoid-break mt-4 border border-slate-200">
          <p className="bg-slate-100 px-3 py-1.5 text-[10px] font-black uppercase tracking-widest text-slate-700">Notes</p>
          <p className="whitespace-pre-wrap px-3 py-2 text-xs font-semibold leading-5">{notes.trim()}</p>
        </div>
      )}

      <div className="print-avoid-break mt-4 border border-[#0f766e]/30 bg-[#0f766e]/5 p-3">
        <p className="text-[10px] font-black uppercase tracking-widest text-[#0f766e]">Important Notice</p>
        <div className="mt-1 grid gap-0.5 text-xs font-bold leading-5 text-slate-700">
          <span>This is a quotation provided for your reference.</span>
          <span>Final price and availability will be confirmed at the time of purchase.</span>
        </div>
      </div>

      <div className="print-avoid-break mt-6 grid gap-6 border-t border-slate-200 pt-5 text-xs font-bold sm:grid-cols-3">
        <div>
          <p className="text-[10px] font-black uppercase tracking-widest text-slate-500">Prepared By</p>
          <div className="mt-7 border-b border-slate-900" />
        </div>
        <div>
          <p className="text-[10px] font-black uppercase tracking-widest text-slate-500">Approved By</p>
          <div className="mt-7 border-b border-slate-900" />
        </div>
        <div>
          <p className="text-[10px] font-black uppercase tracking-widest text-slate-500">Customer Sign</p>
          <div className="mt-7 border-b border-slate-900" />
        </div>
      </div>

      <div className="print-avoid-break mt-5 border-t border-slate-200 pt-3 text-center">
        <p className="text-sm font-black uppercase tracking-widest">{clientConfig.BUSINESS_NAME}</p>
        <p className="mt-1 text-xs font-bold text-slate-500">Thank you for your business</p>
      </div>
    </section>
  );
}
