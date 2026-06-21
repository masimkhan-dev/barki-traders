import { useEffect, useMemo, useRef, useState } from 'react';
import { z } from 'zod';
import { FileText, Plus, Printer, RotateCcw, Trash2 } from 'lucide-react';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { QuotationItem, QuotationPrint } from '@/components/quotations/QuotationPrint';
import { formatNumber } from '@/lib/format';

const fuelTypeSuggestions = ['Diesel', 'Petrol', 'Hi-Octane', 'Kerosene', 'Lubricant'];
const quotationDraftKey = 'fdms-quotation-draft';

const quotationItemSchema = z.object({
  fuelType: z.string().trim().min(1),
  quantity: z.number().positive(),
  rate: z.number().positive(),
});

const createItem = (): QuotationItem => ({
  id: crypto.randomUUID(),
  fuelType: '',
  quantity: 0,
  rate: 0,
});

const formatInputDate = (date: Date) => {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');

  return `${year}-${month}-${day}`;
};

const getTodayInputDate = () => formatInputDate(new Date());

const addDaysToInputDate = (inputDate: string, days: number) => {
  if (!inputDate) return '';

  const [year, month, day] = inputDate.split('-').map(Number);
  if (!year || !month || !day) return '';

  const date = new Date(year, month - 1, day);
  date.setDate(date.getDate() + days);

  return formatInputDate(date);
};

const formatEstimateCurrency = (amount: number) => `Rs ${formatNumber(amount)}`;

const getEstimateNumber = () => {
  const today = getTodayInputDate().replace(/-/g, '');
  const storageKey = `fdms-estimate-counter-${today}`;
  const previousCounter = Number(localStorage.getItem(storageKey) ?? '0');
  const nextCounter = Number.isFinite(previousCounter) ? previousCounter + 1 : 1;
  localStorage.setItem(storageKey, String(nextCounter));

  return `EST-${today}-${String(nextCounter).padStart(3, '0')}`;
};

interface QuotationDraft {
  estimateNo: string;
  estimateDate: string;
  validUntil: string;
  customerName: string;
  customerMobile: string;
  notes: string;
  items: QuotationItem[];
}

const getInitialDraft = (): QuotationDraft => {
  try {
    const savedDraft = localStorage.getItem(quotationDraftKey);
    if (savedDraft) {
      const parsed = JSON.parse(savedDraft) as Partial<QuotationDraft>;
      if (parsed.estimateNo && Array.isArray(parsed.items) && parsed.items.length > 0) {
        return {
          estimateNo: parsed.estimateNo,
          estimateDate: parsed.estimateDate || getTodayInputDate(),
          validUntil: parsed.validUntil || addDaysToInputDate(parsed.estimateDate || getTodayInputDate(), 7),
          customerName: parsed.customerName || '',
          customerMobile: parsed.customerMobile || '',
          notes: parsed.notes || '',
          items: parsed.items.map(item => ({
            id: item.id || crypto.randomUUID(),
            fuelType: item.fuelType || '',
            quantity: Number(item.quantity) || 0,
            rate: Number(item.rate) || 0,
          })),
        };
      }
    }
  } catch {
    localStorage.removeItem(quotationDraftKey);
  }

  const today = getTodayInputDate();
  return {
    estimateNo: getEstimateNumber(),
    estimateDate: today,
    validUntil: addDaysToInputDate(today, 7),
    customerName: '',
    customerMobile: '',
    notes: '',
    items: [createItem()],
  };
};

export default function Quotation() {
  const initialDraft = useMemo(getInitialDraft, []);
  const [estimateNo, setEstimateNo] = useState(initialDraft.estimateNo);
  const [estimateDate, setEstimateDate] = useState(initialDraft.estimateDate);
  const [validUntil, setValidUntil] = useState(initialDraft.validUntil);
  const [customerName, setCustomerName] = useState(initialDraft.customerName);
  const [customerMobile, setCustomerMobile] = useState(initialDraft.customerMobile);
  const [notes, setNotes] = useState(initialDraft.notes);
  const [items, setItems] = useState<QuotationItem[]>(initialDraft.items);
  const hasMountedRef = useRef(false);

  const itemValidation = useMemo(
    () => items.map(item => ({ item, isValid: quotationItemSchema.safeParse(item).success })),
    [items],
  );

  const allItemsValid = itemValidation.every(result => result.isValid);

  const grandTotal = useMemo(
    () => items.reduce((sum, item) => sum + (item.quantity > 0 && item.rate > 0 ? item.quantity * item.rate : 0), 0),
    [items],
  );

  const canPrint = allItemsValid && items.length > 0 && grandTotal > 0;

  useEffect(() => {
    if (!hasMountedRef.current) {
      hasMountedRef.current = true;
      return;
    }

    const draft: QuotationDraft = {
      estimateNo,
      estimateDate,
      validUntil,
      customerName,
      customerMobile,
      notes,
      items,
    };

    localStorage.setItem(quotationDraftKey, JSON.stringify(draft));
  }, [customerMobile, customerName, estimateDate, estimateNo, items, notes, validUntil]);

  const updateItem = <K extends keyof QuotationItem>(id: string, key: K, value: QuotationItem[K]) => {
    setItems(currentItems =>
      currentItems.map(item => (item.id === id ? { ...item, [key]: value } : item)),
    );
  };

  const removeItem = (id: string) => {
    setItems(currentItems => (currentItems.length === 1 ? currentItems : currentItems.filter(item => item.id !== id)));
  };

  const resetForm = () => {
    setEstimateNo(getEstimateNumber());
    const today = getTodayInputDate();
    setEstimateDate(today);
    setValidUntil(addDaysToInputDate(today, 7));
    setCustomerName('');
    setCustomerMobile('');
    setNotes('');
    setItems([createItem()]);
    localStorage.removeItem(quotationDraftKey);
  };

  const printEstimate = () => {
    if (!canPrint) return;
    window.print();
  };

  return (
    <DashboardLayout>
      <style>
        {`
          @media print {
            @page { size: A4; margin: 8mm; }
            body { background: #ffffff !important; }
            header, .no-print { display: none !important; }
            main, main > div { padding: 0 !important; min-height: auto !important; }
            * {
              -webkit-print-color-adjust: exact !important;
              print-color-adjust: exact !important;
            }
            .quotation-print-page {
              border: 0 !important;
              box-shadow: none !important;
              max-width: none !important;
              padding: 0 !important;
              font-size: 11px !important;
            }
            .quotation-print-page table {
              min-width: 0 !important;
            }
            .quotation-print-page tr,
            .quotation-print-page .print-avoid-break {
              break-inside: avoid !important;
              page-break-inside: avoid !important;
            }
          }
        `}
      </style>

      <div className="mx-auto max-w-7xl space-y-6">
        <div className="no-print flex flex-col gap-4 border-b border-slate-200 pb-5 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <div className="flex items-center gap-3">
              <div className="flex h-11 w-11 items-center justify-center bg-slate-900 text-white">
                <FileText className="h-5 w-5" />
              </div>
              <div>
                <p className="text-[10px] font-black uppercase tracking-[0.24em] text-slate-500">
                  Fuel Quotation System
                </p>
                <h1 className="text-2xl font-black tracking-tight text-slate-950">Quotation / Estimate</h1>
              </div>
            </div>
            <p className="mt-3 max-w-2xl text-sm font-semibold text-slate-600">
              Prepare a printable customer estimate without posting an actual sale.
            </p>
          </div>

          <div className="flex flex-wrap gap-2">
            <Button type="button" variant="outline" onClick={resetForm}>
              <RotateCcw className="h-4 w-4" />
              New Estimate
            </Button>
            <Button type="button" onClick={printEstimate} disabled={!canPrint}>
              <Printer className="h-4 w-4" />
              Print / PDF
            </Button>
          </div>
        </div>

        <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(420px,0.9fr)]">
          <section className="no-print space-y-5">
            <div className="bg-white border-2 border-slate-200 p-5">
              <h2 className="text-sm font-black uppercase tracking-widest text-slate-900">Estimate Details</h2>
              <div className="mt-4 grid gap-4 sm:grid-cols-2">
                <label className="space-y-1.5">
                  <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Estimate No</span>
                  <Input value={estimateNo} onChange={event => setEstimateNo(event.target.value)} />
                </label>
                <label className="space-y-1.5">
                  <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Date</span>
                  <Input
                    type="date"
                    value={estimateDate}
                    onChange={event => {
                      setEstimateDate(event.target.value);
                      setValidUntil(addDaysToInputDate(event.target.value, 7));
                    }}
                  />
                </label>
                <label className="space-y-1.5">
                  <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Valid Until</span>
                  <Input type="date" value={validUntil} onChange={event => setValidUntil(event.target.value)} />
                </label>
                <label className="space-y-1.5">
                  <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Status</span>
                  <Input value="Estimate" readOnly className="bg-slate-50" />
                </label>
                <label className="space-y-1.5">
                  <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Customer Name</span>
                  <Input value={customerName} onChange={event => setCustomerName(event.target.value)} placeholder="Optional" />
                </label>
                <label className="space-y-1.5">
                  <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Mobile Number</span>
                  <Input value={customerMobile} onChange={event => setCustomerMobile(event.target.value)} placeholder="Optional" />
                </label>
              </div>
            </div>

            <div className="bg-white border-2 border-slate-200 p-5">
              <div className="flex items-center justify-between gap-3">
                <h2 className="text-sm font-black uppercase tracking-widest text-slate-900">Fuel Items</h2>
                <Button type="button" variant="outline" size="sm" onClick={() => setItems(currentItems => [...currentItems, createItem()])}>
                  <Plus className="h-4 w-4" />
                  Add Item
                </Button>
              </div>

              <datalist id="fuel-type-suggestions">
                {fuelTypeSuggestions.map(fuelType => (
                  <option key={fuelType} value={fuelType} />
                ))}
              </datalist>

              <div className="mt-4 space-y-3">
                {items.map((item, index) => {
                  const lineTotal = item.quantity > 0 && item.rate > 0 ? item.quantity * item.rate : 0;
                  const isRowInvalid = !quotationItemSchema.safeParse(item).success;

                  return (
                    <div key={item.id} className={`grid gap-3 border p-3 sm:grid-cols-[1.2fr_0.8fr_0.8fr_0.8fr_auto] sm:items-end ${isRowInvalid ? 'border-amber-300 bg-amber-50/40' : 'border-slate-200'}`}>
                      <label className="space-y-1.5">
                        <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Fuel Type</span>
                        <Input
                          list="fuel-type-suggestions"
                          value={item.fuelType}
                          onChange={event => updateItem(item.id, 'fuelType', event.target.value)}
                          placeholder={`Item ${index + 1}`}
                        />
                      </label>
                      <label className="space-y-1.5">
                        <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Quantity</span>
                        <Input
                          type="number"
                          min="0"
                          step="0.01"
                          value={item.quantity || ''}
                          onChange={event => updateItem(item.id, 'quantity', Number(event.target.value))}
                          placeholder="Liters"
                        />
                      </label>
                      <label className="space-y-1.5">
                        <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Rate / Ltr</span>
                        <Input
                          type="number"
                          min="0"
                          step="0.01"
                          value={item.rate || ''}
                          onChange={event => updateItem(item.id, 'rate', Number(event.target.value))}
                          placeholder="PKR"
                        />
                      </label>
                      <div className="space-y-1.5">
                        <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Amount</span>
                        <div className="flex h-10 items-center border-2 border-slate-200 bg-slate-50 px-3 text-sm font-black text-slate-900">
                          {formatEstimateCurrency(lineTotal)}
                        </div>
                      </div>
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        onClick={() => removeItem(item.id)}
                        disabled={items.length === 1}
                        aria-label="Remove item"
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </div>
                  );
                })}
              </div>

              <div className="mt-4 flex items-center justify-between border-t-2 border-slate-900 pt-4">
                <span className="text-xs font-black uppercase tracking-widest text-slate-600">Grand Total</span>
                <span className="text-2xl font-black text-slate-950">{formatEstimateCurrency(grandTotal)}</span>
              </div>
            </div>

            <div className="bg-white border-2 border-slate-200 p-5">
              <label className="space-y-1.5">
                <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Notes</span>
                <Textarea
                  value={notes}
                  onChange={event => setNotes(event.target.value)}
                  placeholder="Optional notes, validity, payment terms, or delivery instructions"
                  className="rounded-none border-2 border-slate-200 font-semibold focus-visible:ring-0 focus-visible:border-slate-900"
                />
              </label>
            </div>
          </section>

          <section className="space-y-3">
            <div className="no-print flex items-center justify-between">
              <h2 className="text-sm font-black uppercase tracking-widest text-slate-900">Print Preview</h2>
              {!canPrint && (
                <span className="text-[10px] font-black uppercase tracking-widest text-amber-700">
                  Complete all item rows before printing
                </span>
              )}
            </div>

            <QuotationPrint
              estimateNo={estimateNo}
              estimateDate={estimateDate}
              validUntil={validUntil}
              customerName={customerName}
              customerMobile={customerMobile}
              items={items}
              notes={notes}
              grandTotal={grandTotal}
            />
          </section>
        </div>
      </div>
    </DashboardLayout>
  );
}
