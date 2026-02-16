
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from '@/components/ui/tabs';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { supabase } from '@/integrations/supabase/client';
import { formatPKR } from '@/lib/format';
import { Loader2, Calendar, DollarSign, Activity, TrendingUp, TrendingDown, Scale } from 'lucide-react';
import { cn } from '@/lib/utils';
import { Button } from '@/components/ui/button';
import { DrawingsReport } from '@/components/dashboard/DrawingsReport';

export default function Reports() {
  const [reportDate, setReportDate] = useState(() => new Date().toISOString().split('T')[0]);
  const [startDate, setStartDate] = useState(() => {
    const now = new Date();
    return new Date(now.getFullYear(), now.getMonth(), 1).toISOString().split('T')[0];
  });
  const [endDate, setEndDate] = useState(() => new Date().toISOString().split('T')[0]);

  // DAILY SUMMARY DATA
  const { data: dailyData, isLoading: dailyLoading } = useQuery({
    queryKey: ['daily-summary', reportDate],
    queryFn: async () => {
      // @ts-ignore
      const { data, error } = await supabase.rpc('get_daily_summary' as any, { target_date: reportDate });
      if (error) throw error;
      // returns { total_sales, total_purchases, cash_in, cash_out }
      return data as any;
    }
  });

  // PROFIT & LOSS DATA (Using centralized RPC)
  const { data: pnlData, isLoading: pnlLoading } = useQuery({
    queryKey: ['profit-loss-rpc', startDate, endDate],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_profit_loss' as any, {
        p_start_date: startDate,
        p_end_date: endDate
      });

      if (error) throw error;

      const rows = (data || []) as any[];
      const revenue = rows.filter(r => r.section === 'Income').reduce((sum, r) => sum + Number(r.amount), 0);
      const cogs = rows.filter(r => r.section === 'Direct Costs').reduce((sum, r) => sum + Number(r.amount), 0);
      const expenses = rows.filter(r => r.section === 'Expenses').reduce((sum, r) => sum + Number(r.amount), 0);

      return {
        revenue,
        cogs,
        expenses,
        grossInfo: revenue - cogs,
        netProfit: revenue - cogs - expenses
      };
    }
  });

  // DAILY TRANSACTIONS LIST
  const { data: dailyTx } = useQuery({
    queryKey: ['daily-transactions', reportDate],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('ledger_entries')
        .select(`
          id,
          voucher_no,
          voucher_type,
          narration,
          debit_amount,
          credit_amount,
          account:accounts(name, code),
          party:parties(name)
        `)
        .eq('posting_date', reportDate)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    }
  });


  // Trial Balance / Accounts Data (RPC)
  const { data: accountBalances } = useQuery({
    queryKey: ['account-balances', reportDate],
    queryFn: async () => {
      // @ts-ignore
      const { data, error } = await supabase
        .rpc('get_trial_balance' as any, {
          start_date: '2000-01-01',
          end_date: reportDate
        });

      if (error) throw error;
      return (data as any) as any[];
    }
  });

  return (
    <DashboardLayout>
      <div className="space-y-6">
        <div className="flex flex-col md:flex-row justify-between items-start md:items-center gap-4">
          <div>
            <h1 className="text-3xl font-bold tracking-tight">Business Reports</h1>
            <p className="text-muted-foreground">
              Daily Activities, Profit & Loss, & Accounts
            </p>
          </div>
        </div>

        <Tabs defaultValue="daily" className="space-y-4">
          <TabsList className="bg-muted p-1 rounded-lg w-full md:w-auto grid grid-cols-4">
            <TabsTrigger value="daily" className="flex items-center gap-2">
              <Calendar className="h-4 w-4" />
              <span className="hidden md:inline">Daily Log</span>
              <span className="md:hidden">Daily</span>
            </TabsTrigger>
            <TabsTrigger value="pnl" className="flex items-center gap-2">
              <TrendingUp className="h-4 w-4" />
              <span className="hidden md:inline">Profit/Loss</span>
              <span className="md:hidden">P&L</span>
            </TabsTrigger>
            <TabsTrigger value="accounts" className="flex items-center gap-2">
              <Scale className="h-4 w-4" />
              <span className="hidden md:inline">Trial Balance</span>
              <span className="md:hidden">Trial</span>
            </TabsTrigger>
            <TabsTrigger value="drawings" className="flex items-center gap-2">
              <DollarSign className="h-4 w-4" />
              <span className="hidden md:inline">Drawings</span>
              <span className="md:hidden">Draw</span>
            </TabsTrigger>
          </TabsList>

          {/* 1. DAILY ACTIVITIES */}
          <TabsContent value="daily" className="space-y-4 animate-in fade-in slide-in-from-bottom-5">
            <div className="flex items-center gap-2 bg-white p-2 rounded-lg border w-fit mb-4 shadow-sm">
              <Label htmlFor="report_date" className="whitespace-nowrap font-medium ml-2">Select Date:</Label>
              <Input
                id="report_date"
                type="date"
                value={reportDate}
                onChange={(e) => setReportDate(e.target.value)}
                className="w-40 border-0 focus-visible:ring-0 bg-transparent"
              />
            </div>

            {dailyLoading ? (
              <div className="flex justify-center p-12"><Loader2 className="h-8 w-8 animate-spin text-muted-foreground" /></div>
            ) : (
              <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
                <Card>
                  <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                    <CardTitle className="text-sm font-medium">Total Sales Today</CardTitle>
                    <Activity className="h-4 w-4 text-muted-foreground" />
                  </CardHeader>
                  <CardContent>
                    <div className="text-2xl font-bold">{formatPKR(dailyData?.total_sales || 0)}</div>
                  </CardContent>
                </Card>
                <Card>
                  <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                    <CardTitle className="text-sm font-medium">Total Purchases Today</CardTitle>
                    <Activity className="h-4 w-4 text-muted-foreground" />
                  </CardHeader>
                  <CardContent>
                    <div className="text-2xl font-bold">{formatPKR(dailyData?.total_purchases || 0)}</div>
                  </CardContent>
                </Card>
                <Card>
                  <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                    <CardTitle className="text-sm font-medium">Cash Received</CardTitle>
                    <DollarSign className="h-4 w-4 text-success" />
                  </CardHeader>
                  <CardContent>
                    <div className="text-2xl font-bold text-success">{formatPKR(dailyData?.cash_in || 0)}</div>
                  </CardContent>
                </Card>
                <Card>
                  <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                    <CardTitle className="text-sm font-medium">Cash Sent</CardTitle>
                    <DollarSign className="h-4 w-4 text-destructive" />
                  </CardHeader>
                  <CardContent>
                    <div className="text-2xl font-bold text-destructive">{formatPKR(dailyData?.cash_out || 0)}</div>
                  </CardContent>
                </Card>
              </div>
            )}

            <Card className="mt-6">
              <CardHeader>
                <CardTitle>Transaction Feed ({dailyTx?.length || 0})</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="relative w-full overflow-auto max-h-[400px]">
                  <table className="w-full text-sm text-left">
                    <thead className="bg-muted/50 text-muted-foreground sticky top-0">
                      <tr>
                        <th className="p-3">Ref ID</th>
                        <th className="p-3">Account</th>
                        <th className="p-3">Description</th>
                        <th className="p-3 text-right">Sent (Dr)</th>
                        <th className="p-3 text-right">Received (Cr)</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y">
                      {dailyTx?.map((tx: any, index: number) => (
                        <tr key={`${tx.id || 'tx'}-${index}`} className="hover:bg-muted/50">
                          <td className="p-3 font-mono text-xs uppercase">{tx.voucher_no}</td>
                          <td className="p-3 font-medium">{tx.party?.name || tx.account?.name}</td>
                          <td className="p-3 text-muted-foreground">{tx.narration}</td>
                          <td className="p-3 text-right text-destructive">{tx.debit_amount > 0 ? formatPKR(tx.debit_amount) : '-'}</td>
                          <td className="p-3 text-right text-success">{tx.credit_amount > 0 ? formatPKR(tx.credit_amount) : '-'}</td>
                        </tr>
                      ))}
                      {(!dailyTx || dailyTx.length === 0) && (
                        <tr>
                          <td colSpan={5} className="p-4 text-center text-muted-foreground">No transactions found for this date.</td>
                        </tr>
                      )}
                    </tbody>
                  </table>
                </div>
              </CardContent>
            </Card>
          </TabsContent>

          {/* 2. PROFIT & LOSS */}
          <TabsContent value="pnl" className="space-y-4 animate-in fade-in slide-in-from-bottom-5">
            <div className="flex flex-col md:flex-row items-center gap-4 bg-white p-4 rounded-lg border shadow-sm mb-6">
              <div className="grid gap-1.5 flex-1 w-full">
                <Label>From Date</Label>
                <Input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} />
              </div>
              <div className="grid gap-1.5 flex-1 w-full">
                <Label>To Date</Label>
                <Input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} />
              </div>
              <div className="flex items-end h-full pb-0.5">
                <Button onClick={() => window.print()} variant="outline" size="sm">
                  <Calendar className="mr-2 h-4 w-4" /> Print Report
                </Button>
              </div>
            </div>

            {pnlLoading ? (
              <div className="flex justify-center p-12"><Loader2 className="h-12 w-12 animate-spin text-muted-foreground" /></div>
            ) : (
              <div className="grid gap-6">
                {/* Key Metrics */}
                <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                  <Card className="bg-green-50 border-green-200">
                    <CardHeader className="pb-2">
                      <CardTitle className="text-sm font-medium text-green-700">Total Revenue (Sales)</CardTitle>
                    </CardHeader>
                    <CardContent>
                      <div className="text-3xl font-bold text-green-800">{formatPKR(pnlData?.revenue || 0)}</div>
                    </CardContent>
                  </Card>
                  <Card className="bg-red-50 border-red-200">
                    <CardHeader className="pb-2">
                      <CardTitle className="text-sm font-medium text-red-700">Total Costs (Purchases)</CardTitle>
                    </CardHeader>
                    <CardContent>
                      <div className="text-3xl font-bold text-red-800">{formatPKR(pnlData?.cogs || 0)}</div>
                    </CardContent>
                  </Card>
                  <Card className={cn("border-2", (pnlData?.netProfit || 0) >= 0 ? "bg-blue-50 border-blue-200" : "bg-orange-50 border-orange-200")}>
                    <CardHeader className="pb-2">
                      <CardTitle className="text-sm font-medium">Net Profit / Loss</CardTitle>
                    </CardHeader>
                    <CardContent>
                      <div className={cn("text-3xl font-bold", (pnlData?.netProfit || 0) >= 0 ? "text-blue-700" : "text-orange-700")}>
                        {formatPKR(pnlData?.netProfit || 0)}
                      </div>
                    </CardContent>
                  </Card>
                </div>

                {/* Simple Breakdown Table */}
                <Card>
                  <CardHeader><CardTitle>Financial Breakdown</CardTitle></CardHeader>
                  <CardContent>
                    <table className="w-full text-base">
                      <tbody className="divide-y">
                        <tr>
                          <td className="py-4 font-medium">Sales Income</td>
                          <td className="py-4 text-right">{formatPKR(pnlData?.revenue || 0)}</td>
                        </tr>
                        <tr>
                          <td className="py-4 font-medium text-muted-foreground">(-) Cost of Goods (Purchases)</td>
                          <td className="py-4 text-right text-red-600">({formatPKR(pnlData?.cogs || 0)})</td>
                        </tr>
                        <tr className="bg-gray-50/50">
                          <td className="py-3 font-bold">Gross Profit</td>
                          <td className="py-3 text-right font-bold">{formatPKR(pnlData?.grossInfo || 0)}</td>
                        </tr>
                        <tr>
                          <td className="py-4 font-medium text-muted-foreground">(-) Operating Expenses</td>
                          <td className="py-4 text-right text-red-600">({formatPKR(pnlData?.expenses || 0)})</td>
                        </tr>
                        <tr className="bg-gray-100">
                          <td className="py-4 text-lg font-bold">NET PROFIT</td>
                          <td className={cn("py-4 text-lg text-right font-bold", (pnlData?.netProfit || 0) >= 0 ? "text-blue-700" : "text-red-700")}>
                            {formatPKR(pnlData?.netProfit || 0)}
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </CardContent>
                </Card>
              </div>
            )}
          </TabsContent>

          {/* 3. ACCOUNTS (Trial Balance / List) */}
          <TabsContent value="accounts" className="animate-in fade-in slide-in-from-bottom-5">
            <Card>
              <CardHeader>
                <CardTitle>Chart of Accounts & Balances</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="overflow-x-auto">
                  <table className="w-full text-sm text-left">
                    <thead className="bg-muted/50 text-muted-foreground">
                      <tr>
                        <th className="p-3">Code</th>
                        <th className="p-3">Account Name</th>
                        <th className="p-3">Type</th>
                        <th className="p-3 text-right">Debit</th>
                        <th className="p-3 text-right">Credit</th>
                        <th className="p-3 text-right">Net Balance</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y">
                      {accountBalances?.map((row: any) => (
                        <tr key={row.account_id} className="hover:bg-muted/50">
                          <td className="p-3 font-mono">{row.account_code}</td>
                          <td className="p-3 font-medium">{row.account_name}</td>
                          <td className="p-3 capitalize text-muted-foreground">{row.account_type}</td>
                          <td className="p-3 text-right">{formatPKR(row.total_debit)}</td>
                          <td className="p-3 text-right">{formatPKR(row.total_credit)}</td>
                          <td className={cn("p-3 text-right font-bold", row.net_balance < 0 ? "text-success" : "text-destructive")}>
                            {formatPKR(Math.abs(row.net_balance))} {row.net_balance >= 0 ? 'Dr' : 'Cr'}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </CardContent>
            </Card>
          </TabsContent>

          {/* 4. OWNER DRAWINGS */}
          <TabsContent value="drawings" className="animate-in fade-in slide-in-from-bottom-5">
            <DrawingsReport startDate={startDate} endDate={endDate} />
          </TabsContent>

        </Tabs>
      </div>
    </DashboardLayout >
  );
}
