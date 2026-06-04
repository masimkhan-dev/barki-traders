
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatDate, formatNumber } from '@/lib/format';
import { Loader2, Printer } from 'lucide-react';
import { cn } from '@/lib/utils';
import { Button } from '@/components/ui/button';
import { useReactToPrint } from 'react-to-print';
import { useRef } from 'react';
import { BrandTitle } from '@/components/brand/BrandTitle';

interface CustomerStatementProps {
  customerId: string;
  customerName: string;
  openingBalance: number;
}

interface LedgerTransaction {
  id: string;
  posting_date: string;
  voucher_no: string;
  voucher_type: string;
  narration: string;
  debit_amount: number;
  credit_amount: number;
  running_balance: number;
  quantity?: number;
  rate?: number;
  fuel_type?: string;
}

export function CustomerStatement({ customerId, customerName, openingBalance }: CustomerStatementProps) {
  const printRef = useRef<HTMLDivElement>(null);

  const handlePrint = useReactToPrint({
    contentRef: printRef,
    documentTitle: `${customerName}_Statement`,
  });

  const { data: transactions, isLoading } = useQuery({
    queryKey: ['customer-khata', customerId],
    queryFn: async () => {
      // Fetch Statement from Ledger (RPC)
      const { data, error } = await supabase
        .rpc('get_customer_ledger_statement', { target_customer_id: customerId });

      if (error) throw error;

      return data.map((entry: any) => ({
        id: entry.entry_id,
        date: entry.posting_date,
        voucher_no: entry.voucher_no,
        type: entry.voucher_type,
        narration: entry.narration || '',
        debit: entry.debit_amount,
        credit: entry.credit_amount,
        quantity: entry.quantity,
        rate: entry.rate,
        fuel_type: entry.fuel_type
      }));
    },
  });

  // Calculate Running Balance
  const transactionsWithBalance = transactions?.reduce((acc: any[], t: any, index: number) => {
    const prevBalance = index > 0 ? acc[index - 1].balance : openingBalance;
    // Dr increases Receivable (Asset), Cr decreases it.
    const balance = prevBalance + t.debit - t.credit;
    return [...acc, { ...t, balance }];
  }, []) || [];

  const finalBalance = transactionsWithBalance.length > 0
    ? transactionsWithBalance[transactionsWithBalance.length - 1].balance
    : openingBalance;

  const totalDebits = transactionsWithBalance.reduce((sum, t) => sum + t.debit, 0);
  const totalCredits = transactionsWithBalance.reduce((sum, t) => sum + t.credit, 0);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between no-print">
        <h3 className="text-xl font-bold">Statement: {customerName}</h3>
        <Button onClick={handlePrint} variant="outline" size="sm">
          <Printer className="h-4 w-4 mr-2" />
          Print Statement
        </Button>
      </div>

      <div ref={printRef} className="p-4 bg-white rounded-lg">
        {/* Statement Header for Print - Matches Munshi Style */}
        <div className="mb-6 border-b pb-4">
          <BrandTitle variant="report" className="text-2xl font-bold text-center mb-1 uppercase tracking-wide !text-inherit" />
          <h2 className="text-lg font-semibold text-center mb-6 text-gray-600">ACCOUNT STATEMENT</h2>

          <div className="flex justify-between text-sm bg-gray-50 p-4 rounded border border-gray-100">
            <div className="space-y-1">
              <p><span className="font-bold text-gray-500 w-24 inline-block">Customer:</span> <span className="text-lg font-semibold">{customerName}</span></p>
              <p><span className="font-bold text-gray-500 w-24 inline-block">Generated:</span> {new Date().toLocaleDateString()}</p>
            </div>
            <div className="text-right space-y-1">
              <p><span className="font-bold text-gray-500">Opening Balance:</span> {formatPKR(Math.abs(openingBalance))} {openingBalance >= 0 ? 'Dr' : 'Cr'}</p>
              <p className="text-xl font-bold mt-2 border-t pt-2">
                Net Balance: {formatPKR(Math.abs(finalBalance))} {finalBalance >= 0 ? 'Dr' : 'Cr'}
              </p>
            </div>
          </div>

          {/* Munshi Style Summary Box */}
          <div className="grid grid-cols-3 gap-0 mt-6 border rounded overflow-hidden text-center">
            <div className="p-3 bg-red-50 border-r">
              <p className="text-xs font-bold text-gray-500 uppercase">Total Sales (Debit)</p>
              <p className="text-xl font-bold text-red-600">{formatPKR(totalDebits)}</p>
            </div>
            <div className="p-3 bg-green-50 border-r">
              <p className="text-xs font-bold text-gray-500 uppercase">Total Received (Credit)</p>
              <p className="text-xl font-bold text-green-600">{formatPKR(totalCredits)}</p>
            </div>
            <div className="p-3 bg-gray-50">
              <p className="text-xs font-bold text-gray-500 uppercase">Closing Balance</p>
              <p className={cn("text-xl font-bold", finalBalance >= 0 ? "text-red-600" : "text-green-600")}>
                {formatPKR(Math.abs(finalBalance))} {finalBalance >= 0 ? 'Dr' : 'Cr'}
              </p>
            </div>
          </div>
        </div>

        {/* Loading State */}
        {isLoading ? (
          <div className="flex justify-center py-8">
            <Loader2 className="h-8 w-8 animate-spin" />
          </div>
        ) : (
          <>
            {/* Table - Munshi Layout */}
            <table className="w-full text-xs md:text-sm border-collapse border border-gray-200">
              <thead>
                <tr className="bg-gray-100 text-gray-700">
                  <th className="py-2 px-2 text-left border-r border-b w-[15%]">Date / Bill No</th>
                  <th className="py-2 px-2 text-left border-r border-b w-[25%]">Particulars / Details</th>
                  <th className="py-2 px-2 text-right border-r border-b w-[10%]">Qty</th>
                  <th className="py-2 px-2 text-right border-r border-b w-[10%]">Rate</th>
                  <th className="py-2 px-2 text-right border-r border-b w-[12%] text-red-600">Sent (Diya)</th>
                  <th className="py-2 px-2 text-right border-r border-b w-[12%] text-green-600">Received (Liya)</th>
                  <th className="py-2 px-2 text-right border-b w-[16%]">Lena Hai (Baaqi)</th>
                </tr>
              </thead>
              <tbody>
                {/* OB Row */}
                <tr className="border-b border-gray-200 bg-gray-50">
                  <td className="py-2 px-2 border-r">-</td>
                  <td className="py-2 px-2 border-r font-semibold">Opening Balance</td>
                  <td className="py-2 px-2 border-r text-right">-</td>
                  <td className="py-2 px-2 border-r text-right">-</td>
                  <td className="py-2 px-2 border-r text-right">-</td>
                  <td className="py-2 px-2 border-r text-right">-</td>
                  <td className="py-2 px-2 text-right font-bold">
                    {formatPKR(Math.abs(openingBalance))} {openingBalance >= 0 ? 'Dr' : 'Cr'}
                  </td>
                </tr>

                {transactionsWithBalance.length > 0 ? (
                  transactionsWithBalance.map((t: any) => (
                    <tr key={t.id} className="border-b border-gray-200 hover:bg-gray-50">
                      <td className="py-2 px-2 border-r">
                        <div className="font-medium">{formatDate(t.date)}</div>
                        <div className="text-xs text-gray-500 font-mono">{t.voucher_no}</div>
                      </td>
                      <td className="py-2 px-2 border-r">
                        <div className="font-medium">{t.fuel_type ? t.fuel_type : t.narration}</div>
                        {t.fuel_type && t.narration.includes('Sale -') && (
                          <div className="text-xs text-gray-500">{t.narration.replace('Sale - ', '')}</div>
                        )}
                      </td>
                      <td className="py-2 px-2 border-r text-right font-mono">
                        {t.quantity ? formatNumber(t.quantity) : '-'}
                      </td>
                      <td className="py-2 px-2 border-r text-right font-mono">
                        {t.rate ? formatNumber(t.rate) : '-'}
                      </td>
                      <td className="py-2 px-2 border-r text-right text-red-600 font-medium bg-red-50/30">
                        {t.debit > 0 ? formatPKR(t.debit) : '-'}
                      </td>
                      <td className="py-2 px-2 border-r text-right text-green-600 font-medium bg-green-50/30">
                        {t.credit > 0 ? formatPKR(t.credit) : '-'}
                      </td>
                      <td className="py-2 px-2 text-right font-bold font-mono">
                        {formatPKR(Math.abs(t.balance))} {t.balance >= 0 ? 'Dr' : 'Cr'}
                      </td>
                    </tr>
                  ))
                ) : (
                  <tr>
                    <td colSpan={7} className="text-center py-12 text-muted-foreground">
                      No transactions found during this period.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>

            {/* Print Footer */}
            <div className="mt-12 pt-8 border-t flex justify-between text-xs text-gray-400">
              <p>Printed on {new Date().toLocaleString()}</p>
              <div className="space-x-12">
                <span>Accountant Signature: __________________</span>
                <span>Customer Signature: __________________</span>
              </div>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
