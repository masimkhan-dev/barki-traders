import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { supabase } from '@/integrations/supabase/client';
import { toast } from 'sonner';
import { Banknote, Loader2, Check, AlertCircle } from 'lucide-react';
import { formatPKR } from '@/lib/format';

export default function SetupOpeningBalance() {
    const [cashAmount, setCashAmount] = useState('');
    const [bankAmount, setBankAmount] = useState('');
    const [openingDate, setOpeningDate] = useState(() => {
        const thirtyDaysAgo = new Date();
        thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
        return thirtyDaysAgo.toISOString().split('T')[0];
    });
    const [isLoading, setIsLoading] = useState(false);
    const [isSuccess, setIsSuccess] = useState(false);
    const [isAlreadyConfigured, setIsAlreadyConfigured] = useState(false);

    // Check if opening balances already exist on mount
    const { data: existingOpening, isLoading: checkedExisting } = useQuery({
        queryKey: ['check-opening-exists'],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('ledger_entries')
                .select('id')
                .eq('voucher_type', 'opening')
                .limit(1);
            if (error) throw error;
            if (data && data.length > 0) {
                setIsAlreadyConfigured(true);
            }
            return data;
        }
    });

    const handleSubmit = async (e: React.FormEvent) => {
        e.preventDefault();

        const cash = parseFloat(cashAmount) || 0;
        const bank = parseFloat(bankAmount) || 0;

        if (cash <= 0 && bank <= 0) {
            toast.error('Please enter at least one opening balance');
            return;
        }

        if (cash < 0 || bank < 0) {
            toast.error('Opening balances cannot be negative');
            return;
        }

        setIsLoading(true);

        try {
            const { data, error } = await (supabase as any).rpc('setup_opening_balances', {
                p_cash_amount: cash,
                p_bank_amount: bank,
                p_opening_date: openingDate,
            });

            if (error) throw error;

            setIsSuccess(true);
            setIsAlreadyConfigured(true);
            toast.success('Opening balances created successfully!', {
                description: `Total Capital: ${formatPKR(cash + bank)}`,
            });

            setCashAmount('');
            setBankAmount('');

        } catch (error: any) {
            console.error('Error creating opening balances:', error);
            toast.error(error.message || 'Failed to create opening balances');
        } finally {
            setIsLoading(false);
        }
    };

    const totalCapital = (parseFloat(cashAmount) || 0) + (parseFloat(bankAmount) || 0);

    return (

        <DashboardLayout>
            <div className="max-w-4xl mx-auto pb-20 px-6">
                <div className="report-header mb-8">
                    <h1 className="report-title">Initialize Opening Balances</h1>
                    <p className="report-subtitle">Establish starting financial position for Cash & Bank Ledger</p>
                </div>

                {isSuccess ? (
                    /* Success State */
                    <div className="border border-emerald-300 bg-emerald-50 p-12 flex flex-col items-center justify-center text-center space-y-6">
                        <div className="h-16 w-16 bg-emerald-100 flex items-center justify-center border border-emerald-200">
                            <Check className="h-8 w-8 text-emerald-600" />
                        </div>
                        <div>
                            <h3 className="text-xl font-black text-emerald-900 uppercase">Configuration Successful</h3>
                            <p className="text-emerald-700 mt-1 font-bold text-xs uppercase tracking-widest">
                                Opening Statement has been committed to the ledger.
                            </p>
                        </div>
                        <Button
                            onClick={() => setIsSuccess(false)}
                            variant="outline"
                            className="rounded-none border-emerald-300 hover:bg-emerald-100 font-black text-[10px] uppercase tracking-widest px-8"
                        >
                            Create Another Entry
                        </Button>
                    </div>
                ) : (
                    /* Form */
                    <form onSubmit={handleSubmit} className="space-y-6">
                        <div className="border border-slate-300 bg-white p-8">
                            <div className="flex items-center gap-2 mb-8 pb-4 border-b border-slate-100">
                                <Banknote className="h-4 w-4 text-slate-400" />
                                <h2 className="text-sm font-black uppercase tracking-widest">Initial Capital Configuration</h2>
                            </div>

                            <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                {/* Opening Date */}
                                <div className="space-y-2">
                                    <Label className="text-[10px] font-black uppercase text-slate-500">Opening (Cut-off) Date</Label>
                                    <Input
                                        type="date"
                                        value={openingDate}
                                        onChange={(e) => setOpeningDate(e.target.value)}
                                        required
                                        className="rounded-none border-slate-300 font-bold h-11"
                                    />
                                    <p className="text-[10px] text-slate-400 italic font-medium">
                                        System will ignore transactions prior to this date.
                                    </p>
                                </div>

                                {/* Total Capital Summary */}
                                <div className="flex flex-col justify-end">
                                    {totalCapital > 0 && (
                                        <div className="bg-slate-900 text-white p-4 border-l-4 border-emerald-500">
                                            <span className="text-[9px] font-black uppercase text-slate-400 block mb-1">Proposed Opening Equity:</span>
                                            <span className="text-2xl font-black num-audit">
                                                {formatPKR(totalCapital)}
                                            </span>
                                        </div>
                                    )}
                                </div>
                            </div>

                            <div className="grid grid-cols-1 md:grid-cols-2 gap-8 mt-8">
                                {/* Cash Amount */}
                                <div className="space-y-2">
                                    <Label className="text-[10px] font-black uppercase text-slate-500">Physical Cash on Hand (Rs.)</Label>
                                    <Input
                                        type="number"
                                        placeholder="0.00"
                                        value={cashAmount}
                                        onChange={(e) => setCashAmount(e.target.value)}
                                        min="0"
                                        step="0.01"
                                        className="text-xl font-black num-audit rounded-none border-slate-300 h-12"
                                    />
                                    <p className="text-[10px] text-slate-400 italic">
                                        Total un-deposited cash at business vault/safe.
                                    </p>
                                </div>

                                {/* Bank Amount */}
                                <div className="space-y-2">
                                    <Label className="text-[10px] font-black uppercase text-slate-500">Consolidated Bank Balance (Rs.)</Label>
                                    <Input
                                        type="number"
                                        placeholder="0.00"
                                        value={bankAmount}
                                        onChange={(e) => setBankAmount(e.target.value)}
                                        min="0"
                                        step="0.01"
                                        className="text-xl font-black num-audit rounded-none border-slate-300 h-12"
                                    />
                                    <p className="text-[10px] text-slate-400 italic">
                                        Verified statement balance of all business accounts.
                                    </p>
                                </div>
                            </div>

                            {/* Submit Button */}
                            <div className="pt-8 border-t border-slate-100 mt-8 space-y-4">
                                {isAlreadyConfigured && (
                                    <div className="flex items-center gap-3 p-4 bg-amber-50 border border-amber-200 text-amber-800">
                                        <AlertCircle className="h-5 w-5 shrink-0" />
                                        <p className="text-[10px] font-black uppercase leading-tight tracking-wider">
                                            System has detected existing opening entries. Modifying this will disrupt audit logs. Wizard disabled.
                                        </p>
                                    </div>
                                )}
                                <Button
                                    type="submit"
                                    className="w-full bg-slate-900 hover:bg-black text-white rounded-none h-12 font-black uppercase tracking-[0.2em] text-xs"
                                    disabled={isLoading || totalCapital <= 0 || isAlreadyConfigured}
                                >
                                    {isLoading ? (
                                        <>
                                            <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                                            Synchronizing Ledger...
                                        </>
                                    ) : (
                                        <>
                                            <Check className="mr-2 h-4 w-4" />
                                            Finalize & Commit Initial Position
                                        </>
                                    )}
                                </Button>
                            </div>
                        </div>
                    </form>
                )}

                {/* Info Card */}
                <div className="mt-8 border border-slate-200 p-6 bg-slate-50">
                    <h4 className="font-black text-[11px] uppercase tracking-widest text-slate-900 mb-4 border-b border-slate-200 pb-2">Technical Audit Notes:</h4>
                    <ul className="text-[10px] text-slate-600 space-y-2 font-bold uppercase tracking-tight">
                        <li className="flex items-start gap-2"><span className="text-slate-900">•</span> Opening balances are immutable once verified by the Munshi.</li>
                        <li className="flex items-start gap-2"><span className="text-slate-900">•</span> Amounts represent the starting point of the current accounting period.</li>
                        <li className="flex items-start gap-2"><span className="text-slate-900">•</span> Reconciliation must be performed against physical cash count on the cut-off date.</li>
                        <li className="flex items-start gap-2"><span className="text-slate-900">•</span> Operation is restricted if forward-dated transactions already exist in ledger.</li>
                    </ul>
                </div>
            </div>
        </DashboardLayout>

    );
}
