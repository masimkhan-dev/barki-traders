import {
  AlertTriangle,
  BarChart3,
  BookOpenCheck,
  FileText,
  LifeBuoy,
  ListChecks,
  Package,
  Printer,
  ShieldCheck,
  ShoppingCart,
  Truck,
  Users,
  Workflow,
} from 'lucide-react';
import { useEffect, useState } from 'react';
import { clientConfig } from '@/lib/client-config';

const workflowSteps = [
  'Record daily fuel sales, purchases, receipts, payments, and adjustments.',
  'Review saved transactions from the audit screen before relying on reports.',
  'Check inventory, ledger, trial balance, profit/loss, and balance sheet reports.',
  'Print or export reports when sharing results with owners, accountants, or auditors.',
];

const features = [
  {
    icon: ShoppingCart,
    title: 'Fuel Sale',
    description: 'Use this to enter customer sales and keep sale records connected with ledger posting.',
  },
  {
    icon: Truck,
    title: 'Fuel Purchase',
    description: 'Use this to record supplier purchases and update stock movement.',
  },
  {
    icon: Workflow,
    title: 'Transactions',
    description: 'Use this as the main control area for vouchers, payments, receipts, and adjustments.',
  },
  {
    icon: Package,
    title: 'Stock',
    description: 'Use this to review current fuel inventory and movement.',
  },
  {
    icon: FileText,
    title: 'Party Statement',
    description: 'Use this to view customer or supplier account history.',
  },
  {
    icon: BarChart3,
    title: 'Reports',
    description: 'Use reports for market position, trial balance, profit/loss, and balance sheet review.',
  },
];

const quickStart = [
  {
    icon: Users,
    title: 'Create/Add Data',
    description: 'Add accounts, parties, fuel records, and opening balances before daily posting.',
  },
  {
    icon: ListChecks,
    title: 'Manage Records',
    description: 'Use the Transactions screen to review, correct, or reverse records when needed.',
  },
  {
    icon: BookOpenCheck,
    title: 'View Reports',
    description: 'Open ledger and financial reports to confirm balances and business position.',
  },
  {
    icon: Printer,
    title: 'Export or Print Results',
    description: 'Print reports or export CSV files for sharing and record keeping.',
  },
];

// TEMPORARY ONBOARDING SECTION:
// TODO: Remove this onboarding section before final production deployment if requested by the client.
export function GettingStarted() {
  const [collapsed, setCollapsed] = useState(true);

  useEffect(() => {
    const saved = localStorage.getItem('barki_guide_collapsed');
    setCollapsed(saved === null ? true : saved === 'true');
  }, []);

  const toggleCollapsed = () => {
    const next = !collapsed;
    setCollapsed(next);
    localStorage.setItem('barki_guide_collapsed', String(next));
  };

  return (
    <section className="bg-white border border-[var(--color-card-border)] rounded-xl shadow-sm overflow-hidden">
      <div className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-3">
          <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-[var(--color-primary-light)] text-[var(--color-primary)]">
            <BookOpenCheck className="h-4 w-4" />
          </div>
          <div>
            <p className="text-sm font-semibold text-[var(--color-text-primary)]">
              How to use this system
            </p>
            <p className="text-xs font-medium text-[var(--color-text-muted)]">
              Temporary guide for demonstration and client onboarding.
            </p>
          </div>
        </div>
        <button
          type="button"
          onClick={toggleCollapsed}
          className="w-full sm:w-auto border border-[var(--color-primary)] text-[var(--color-primary)] rounded-md px-3.5 py-1.5 text-xs font-semibold hover:bg-[var(--color-primary-light)]"
        >
          {collapsed ? 'Show Guide' : 'Hide Guide'}
        </button>
      </div>

      {!collapsed && (
        <>
      <div className="p-5 sm:p-6 lg:p-7 border-b border-slate-200">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div className="flex items-start gap-4">
            <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-lg bg-[var(--color-primary)] text-white">
              <BookOpenCheck className="h-5 w-5" />
            </div>
            <div className="min-w-0">
              <p className="text-[10px] font-black uppercase tracking-[0.18em] text-slate-500">
                Temporary Client Onboarding
              </p>
              <h2 className="mt-1 text-xl sm:text-2xl font-black uppercase tracking-tight text-slate-900">
                How to Use This Software
              </h2>
              <p className="mt-2 max-w-3xl text-sm font-medium leading-6 text-slate-600">
                Welcome to {clientConfig.BUSINESS_NAME}. This system helps manage fuel sales,
                purchases, inventory, accounts, and financial reports from one secure dashboard.
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2 border border-transparent bg-[var(--color-success-light)] px-3 py-2 text-[var(--color-success-text)] rounded-full">
            <ShieldCheck className="h-4 w-4 shrink-0" />
            <span className="text-[10px] font-black uppercase tracking-widest">
              Demo Guide
            </span>
          </div>
        </div>
      </div>

      <div className="grid gap-0 lg:grid-cols-[1fr_1.05fr]">
        <div className="p-5 sm:p-6 lg:p-7 border-b lg:border-b-0 lg:border-r border-slate-200">
          <div className="flex items-center gap-3 mb-5">
            <Workflow className="h-5 w-5 text-slate-700" />
            <h3 className="text-sm font-black uppercase tracking-widest text-slate-800">
              How It Works
            </h3>
          </div>

          <ol className="space-y-3">
            {workflowSteps.map((step, index) => (
              <li key={step} className="flex gap-3">
                <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-[var(--color-primary)] text-[11px] font-black text-white">
                  {index + 1}
                </span>
                <p className="pt-1 text-sm font-semibold leading-6 text-slate-700">
                  {step}
                </p>
              </li>
            ))}
          </ol>
        </div>

        <div className="p-5 sm:p-6 lg:p-7">
          <div className="flex items-center gap-3 mb-5">
            <ListChecks className="h-5 w-5 text-slate-700" />
            <h3 className="text-sm font-black uppercase tracking-widest text-slate-800">
              Main Features
            </h3>
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            {features.map((feature) => {
              const Icon = feature.icon;
              return (
                <div key={feature.title} className="border border-[var(--color-card-border)] bg-slate-50/60 rounded-lg p-4">
                  <div className="flex items-center gap-2">
                    <Icon className="h-4 w-4 text-slate-700" />
                    <h4 className="text-xs font-black uppercase tracking-wide text-slate-900">
                      {feature.title}
                    </h4>
                  </div>
                  <p className="mt-2 text-xs font-medium leading-5 text-slate-600">
                    {feature.description}
                  </p>
                </div>
              );
            })}
          </div>
        </div>
      </div>

      <div className="grid gap-0 border-t border-slate-200 lg:grid-cols-[1.4fr_0.9fr]">
        <div className="p-5 sm:p-6 lg:p-7 border-b lg:border-b-0 lg:border-r border-slate-200">
          <div className="flex items-center gap-3 mb-5">
            <BookOpenCheck className="h-5 w-5 text-slate-700" />
            <h3 className="text-sm font-black uppercase tracking-widest text-slate-800">
              Quick Start Guide
            </h3>
          </div>

          <ol className="grid gap-3 sm:grid-cols-2">
            {quickStart.map((item, index) => {
              const Icon = item.icon;
              return (
                <li key={item.title} className="border border-[var(--color-card-border)] rounded-lg p-4">
                  <div className="flex items-center gap-3">
                    <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-[var(--color-primary)] text-[11px] font-black text-white">
                      {index + 1}
                    </span>
                    <Icon className="h-4 w-4 text-slate-700" />
                    <h4 className="text-xs font-black uppercase tracking-wide text-slate-900">
                      {item.title}
                    </h4>
                  </div>
                  <p className="mt-3 text-xs font-medium leading-5 text-slate-600">
                    {item.description}
                  </p>
                </li>
              );
            })}
          </ol>
        </div>

        <div className="p-5 sm:p-6 lg:p-7 space-y-5">
          <div>
            <div className="flex items-center gap-3 mb-3">
              <AlertTriangle className="h-5 w-5 text-amber-600" />
              <h3 className="text-sm font-black uppercase tracking-widest text-slate-800">
                Important Notes
              </h3>
            </div>
            <ol className="space-y-2 text-xs font-semibold leading-5 text-slate-600">
              <li>1. Enter accurate dates, party names, quantities, and rates before saving.</li>
              <li>2. Review reports regularly so account balances stay clear.</li>
              <li>3. Use reversal/correction flows instead of deleting financial records.</li>
              <li>4. Keep login access limited to authorized staff only.</li>
            </ol>
          </div>

          <div className="border border-[var(--color-card-border)] bg-slate-50 rounded-lg p-4">
            <div className="flex items-center gap-3">
              <LifeBuoy className="h-5 w-5 text-slate-700" />
              <h3 className="text-sm font-black uppercase tracking-widest text-slate-800">
                Support
              </h3>
            </div>
            <p className="mt-3 text-xs font-semibold leading-5 text-slate-600">
              For help, contact the system administrator or the implementation team that set up
              this {clientConfig.TAGLINE} for {clientConfig.BUSINESS_NAME}.
            </p>
          </div>
        </div>
      </div>
        </>
      )}
    </section>
  );
}
