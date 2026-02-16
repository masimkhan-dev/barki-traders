import { forwardRef } from 'react';
import { formatPKR, formatDate } from '@/lib/format';

interface PrintVoucherProps {
  voucher: {
    voucher_no: string;
    date: string;
    party_name: string;
    party_type: 'customer' | 'supplier';
    voucher_type: 'sale' | 'purchase' | 'receipt' | 'payment';
    previous_balance: number;
    transaction_amount: number;
    new_balance: number;
    fuel_type?: string;
    quantity?: number;
    rate?: number;
    notes?: string;
    payment_method?: string;
  };
}

const getVoucherTitle = (type: string) => {
  switch (type) {
    case 'sale': return 'Sale Voucher';
    case 'purchase': return 'Purchase Voucher';
    case 'receipt': return 'Receipt Voucher';
    case 'payment': return 'Payment Voucher';
    default: return 'Voucher';
  }
};

export const PrintVoucher = forwardRef<HTMLDivElement, PrintVoucherProps>(
  ({ voucher }, ref) => {
    const balanceLabel = voucher.previous_balance >= 0 ? 'Dr' : 'Cr';
    const newBalanceLabel = voucher.new_balance >= 0 ? 'Dr' : 'Cr';

    return (
      <div ref={ref} className="print-voucher p-4 bg-white text-black min-w-[300px] max-w-[400px] font-mono text-sm">
        {/* Header */}
        <div className="text-center border-b border-black pb-2 mb-3">
          <h1 className="text-lg font-bold">NAVEED MUSAZAI FUEL</h1>
          <p className="text-xs">{getVoucherTitle(voucher.voucher_type)}</p>
        </div>

        {/* Voucher Info */}
        <div className="flex justify-between mb-3 text-xs">
          <span>Voucher: {voucher.voucher_no}</span>
          <span>Date: {formatDate(voucher.date)}</span>
        </div>

        {/* Party Info */}
        <div className="border-t border-b border-dashed border-gray-400 py-2 mb-3">
          <div className="flex justify-between">
            <span className="font-bold">{voucher.party_type === 'customer' ? 'Customer:' : 'Supplier:'}</span>
            <span>{voucher.party_name}</span>
          </div>
        </div>

        {/* Transaction Details for Sale/Purchase */}
        {voucher.fuel_type && (
          <div className="mb-3 text-xs">
            <div className="flex justify-between">
              <span>Fuel Type:</span>
              <span>{voucher.fuel_type}</span>
            </div>
            {voucher.quantity && (
              <div className="flex justify-between">
                <span>Quantity:</span>
                <span>{voucher.quantity} Liters</span>
              </div>
            )}
            {voucher.rate && (
              <div className="flex justify-between">
                <span>Rate:</span>
                <span>{formatPKR(voucher.rate)}/L</span>
              </div>
            )}
          </div>
        )}

        {/* Payment Method for Receipt/Payment */}
        {voucher.payment_method && (
          <div className="mb-3 text-xs">
            <div className="flex justify-between">
              <span>Payment Method:</span>
              <span>{voucher.payment_method}</span>
            </div>
          </div>
        )}

        {/* Balance Summary */}
        <div className="border-t border-dashed border-gray-400 pt-2 space-y-1">
          <div className="flex justify-between text-xs">
            <span>Previous Balance:</span>
            <span>{formatPKR(Math.abs(voucher.previous_balance))} {balanceLabel}</span>
          </div>
          <div className="flex justify-between font-bold">
            <span>This Transaction:</span>
            <span>{formatPKR(voucher.transaction_amount)}</span>
          </div>
          <div className="flex justify-between font-bold text-base border-t border-black pt-1 mt-1">
            <span>New Balance:</span>
            <span>{formatPKR(Math.abs(voucher.new_balance))} {newBalanceLabel}</span>
          </div>
        </div>

        {/* Notes */}
        {voucher.notes && (
          <div className="mt-3 text-xs border-t border-dashed border-gray-400 pt-2">
            <span className="font-bold">Notes:</span> {voucher.notes}
          </div>
        )}

        {/* Footer */}
        <div className="mt-4 pt-2 border-t border-black text-center text-xs">
          <p>Thank you for your business!</p>
        </div>
      </div>
    );
  }
);

PrintVoucher.displayName = 'PrintVoucher';
