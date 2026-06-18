import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Card } from '@/components/ui/card';
import { useAuth } from '@/contexts/AuthContext';
import { CalendarClock, DatabaseBackup, ShieldCheck } from 'lucide-react';

export default function BackupCenter() {
  const { role } = useAuth();
  const canViewBackup = role === 'admin' || role === 'accountant';

  if (!canViewBackup) {
    return (
      <DashboardLayout>
        <div className="flex min-h-[60vh] items-center justify-center">
          <Card className="max-w-md rounded-none border-slate-300 p-8 text-center">
            <ShieldCheck className="mx-auto mb-4 h-10 w-10 text-slate-400" />
            <h1 className="text-lg font-black uppercase tracking-widest text-slate-900">Access Restricted</h1>
            <p className="mt-2 text-sm font-medium text-slate-500">
              Only authorized staff can access the backup center.
            </p>
          </Card>
        </div>
      </DashboardLayout>
    );
  }

  return (
    <DashboardLayout>
      <div className="mx-auto max-w-4xl px-4 py-8">
        <div className="mb-8">
          <h1 className="text-2xl font-black uppercase tracking-tight text-slate-900">Backup Center</h1>
          <p className="mt-1 text-sm font-semibold text-slate-500">
            Secure business backup module for accounting and operational records.
          </p>
        </div>

        <Card className="rounded-none border-slate-300 p-8">
          <div className="flex flex-col gap-6 md:flex-row md:items-start">
            <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-none border border-slate-300 bg-slate-50">
              <DatabaseBackup className="h-7 w-7 text-[#0f766e]" />
            </div>

            <div className="flex-1">
              <div className="inline-flex items-center gap-2 border border-amber-300 bg-amber-50 px-3 py-1 text-[10px] font-black uppercase tracking-widest text-amber-700">
                <CalendarClock className="h-3.5 w-3.5" />
                Coming Soon
              </div>

              <h2 className="mt-4 text-xl font-black uppercase tracking-tight text-slate-900">
                Backup export is under preparation
              </h2>

              <p className="mt-3 max-w-2xl text-sm font-medium leading-relaxed text-slate-600">
                This module is being finalized to provide a safe, readable Excel backup of core business
                records including sales, purchases, payments, ledger entries, inventory, parties, accounts,
                and running balances.
              </p>

              <div className="mt-6 border-l-4 border-[#0f766e] bg-slate-50 px-4 py-3">
                <p className="text-xs font-bold uppercase tracking-widest text-slate-500">
                  Status
                </p>
                <p className="mt-1 text-sm font-semibold text-slate-800">
                  Backup download is temporarily disabled while final verification is completed.
                </p>
              </div>
            </div>
          </div>
        </Card>
      </div>
    </DashboardLayout>
  );
}
