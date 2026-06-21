import React, { useEffect, useRef, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import {
  LayoutDashboard,
  FileText,
  Users,
  Truck,
  ShoppingCart,
  Receipt,
  Wallet,
  BarChart3,
  Package,
  LogOut,
  Building2,
  UserCircle,
  CalendarDays,
  ArrowRightLeft,
  FileMinus,
  BookOpen,
  UserCircle2,
  Lock,
  Shield,
  KeyRound,
  Loader2,
  CheckCircle2,
  DatabaseBackup,
  FileSignature
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { cn } from '@/lib/utils';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';
import { clientConfig } from '@/lib/client-config';

interface NavItem {
  label: string;
  href: string;
  icon: React.ElementType;
  section: 'Main' | 'Operations' | 'Reports' | 'Admin';
  roles?: ('admin' | 'accountant')[];
  disabled?: boolean;
  helper?: string;
}

const navItems: NavItem[] = [
  { label: 'Dashboard', href: '/dashboard', icon: LayoutDashboard, section: 'Main' },
  { label: 'Daily Diary', href: '/roznamcha', icon: CalendarDays, section: 'Main', roles: ['admin', 'accountant'] },

  { label: 'Fuel Sale', href: '/manage-transactions?type=SALE', icon: ShoppingCart, section: 'Operations', roles: ['admin', 'accountant'] },
  { label: 'Quotation / Estimate', href: '/quotations', icon: FileSignature, section: 'Operations', roles: ['admin', 'accountant'] },
  { label: 'Fuel Purchase', href: '/manage-transactions?type=PURCHASE', icon: Truck, section: 'Operations', roles: ['admin', 'accountant'] },
  { label: 'Transactions', href: '/manage-transactions?type=ACTION_CENTER', icon: ArrowRightLeft, section: 'Operations', roles: ['admin', 'accountant'] },
  { label: 'Stock', href: '/inventory', icon: Package, section: 'Operations' },
  { label: 'Ledger', href: '/ledger', icon: BookOpen, section: 'Operations' },

  { label: 'Party Statement', href: '/reports/account-statement', icon: FileText, section: 'Reports' },
  { label: 'Market Position', href: '/reports/business', icon: BarChart3, section: 'Reports' },
  { label: 'Income Statement', href: '/reports/profit-loss', icon: Receipt, section: 'Reports' },
  { label: 'Trial Balance', href: '/reports/trial-balance', icon: Wallet, section: 'Reports' },
  { label: 'Balance Sheet', href: '/reports/balance-sheet', icon: FileMinus, section: 'Reports' },

  { label: 'Manage Accounts', href: '/settings/coa', icon: Building2, section: 'Admin', roles: ['admin', 'accountant'] },
  { label: 'Access Control', href: '/users', icon: UserCircle, section: 'Admin', roles: ['admin'] },
  { label: 'Backup Center', href: '/settings/backup', icon: DatabaseBackup, section: 'Admin', roles: ['admin', 'accountant'] },
  { label: 'Month-End Closing', href: '/month-end-closing', icon: Lock, section: 'Admin', roles: ['admin'], disabled: true, helper: 'Coming soon' },
  { label: 'Capital Report', href: '/reports/capital', icon: UserCircle2, section: 'Admin', roles: ['admin'], disabled: true, helper: 'Coming soon' },
];

const sectionOrder: NavItem['section'][] = ['Main', 'Operations', 'Reports', 'Admin'];


export function Sidebar({ className, onItemClick }: { className?: string, onItemClick?: () => void }) {
  const location = useLocation();
  const { user, role, signOut } = useAuth();
  const navRef = useRef<HTMLElement>(null);

  // Restore scroll position on mount and navigation
  useEffect(() => {
    const savedScrollPos = sessionStorage.getItem('sidebar-scroll-pos');
    if (savedScrollPos && navRef.current) {
      // Use a small timeout to ensure the DOM has finished rendering
      const timeoutId = setTimeout(() => {
        if (navRef.current) {
          navRef.current.scrollTop = parseInt(savedScrollPos, 10);
        }
      }, 0);
      return () => clearTimeout(timeoutId);
    }
  }, [location.pathname]);

  const handleScroll = (e: React.UIEvent<HTMLElement>) => {
    sessionStorage.setItem('sidebar-scroll-pos', e.currentTarget.scrollTop.toString());
  };

  const filteredNavItems = navItems.filter(item => {
    if (item.disabled) return false;
    if (!item.roles) return true;
    return role && item.roles.includes(role);
  });

  const isFixed = className?.includes('fixed') || (!className?.includes('relative') && !className?.includes('static'));

  return (

    <aside className={cn(
      isFixed ? "fixed left-0 top-0 z-40 h-screen w-72 bg-[var(--color-sidebar-bg)] border-r border-[#2E2E42]" : "w-full h-full bg-[var(--color-sidebar-bg)]",
      className
    )}>
      <div className="flex flex-col h-full">
        {/* BRANDING SECTION */}
        <div className="p-5 lg:p-6 border-b border-[#2E2E42] bg-[#16162A]">
          <Link to="/" onClick={onItemClick} className="flex flex-col gap-1 focus-visible:outline-white" aria-label="Go to dashboard home">
            <div className="flex items-center gap-3">
              <div className="flex h-11 w-11 items-center justify-center rounded-lg bg-[var(--color-sidebar-bg)] border border-[#2E2E42] overflow-hidden p-1.5">
                <img src={clientConfig.LOGO_PATH} alt={clientConfig.BUSINESS_NAME} className="h-full w-full object-contain filter brightness-110" />
              </div>
              <div className="flex flex-col min-w-0">
                <span className="text-xl text-white font-black uppercase tracking-normal leading-none">
                  NEXLY
                </span>
                <span className="text-[11px] text-[#A1A1AA] font-bold uppercase tracking-[0.12em] mt-1">
                  {clientConfig.BUSINESS_NAME}
                </span>
              </div>
            </div>
          </Link>
        </div>

        {/* NAVIGATION AREA */}
        <nav
          ref={navRef}
          onScroll={handleScroll}
          className="flex-1 px-3 py-4 overflow-y-auto scrollbar-none"
          aria-label="Primary navigation"
        >
          {sectionOrder.map((section) => {
            const items = filteredNavItems.filter(item => item.section === section);
            if (items.length === 0) return null;

            return (
              <div key={section} className="mb-5 last:mb-0">
                <div className="px-3 pb-2 text-[10px] font-bold uppercase tracking-[0.18em] text-[#71717A]">
                  {section}
                </div>

                <div className="space-y-1">
                  {items.map((item) => {
                    const [itemPath, itemSearch] = item.href.split('?');
                    const isActive =
                      location.pathname === itemPath &&
                      (!itemSearch || location.search === `?${itemSearch}`);
                    const Icon = item.icon;

                    if (item.disabled) {
                      return (
                        <div
                          key={item.href}
                          className="flex min-h-10 items-center gap-3 px-3.5 py-2.5 rounded-md border border-transparent text-slate-600 cursor-not-allowed opacity-70"
                          title={item.helper}
                          aria-disabled="true"
                        >
                          <Icon className="h-4 w-4 flex-shrink-0 text-slate-700" />
                          <span className="font-semibold text-[13px] leading-snug flex-1">{item.label}</span>
                          {item.helper && (
                            <span className="text-[9px] font-black uppercase tracking-normal text-slate-500 border border-slate-800 px-1.5 py-0.5">
                              Soon
                            </span>
                          )}
                        </div>
                      );
                    }

                    return (
                      <Link
                        key={item.href}
                        to={item.href}
                        onClick={onItemClick}
                        className={cn(
                          'flex min-h-11 items-center gap-3 px-3.5 py-2.5 rounded-md transition-all duration-150 group border focus-visible:outline-white',
                          isActive
                            ? 'bg-[rgba(79,70,229,0.10)] text-white border-transparent border-l-[3px] border-l-[var(--color-primary)]'
                            : 'text-[#A1A1AA] border-transparent border-l-[3px] border-l-transparent hover:bg-white/[0.03] hover:text-white'
                        )}
                      >
                        <span className={cn(
                          'flex h-8 w-8 shrink-0 items-center justify-center transition-colors duration-150',
                          isActive ? 'text-white' : 'text-[#A1A1AA] group-hover:text-white'
                        )}>
                          <Icon className="h-4 w-4" />
                        </span>
                        <span className="font-semibold text-[13px] leading-snug">{item.label}</span>
                      </Link>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </nav>

        {/* USER PROFILE SECTION */}
        <div className="bg-[#16162A] border-t border-[#2E2E42] px-3 py-2.5">
          <div className="flex items-center gap-2.5 px-2 pb-2">
            <div className="flex h-7 w-7 items-center justify-center rounded-full bg-[var(--color-primary)] shrink-0 border border-transparent">
              <UserCircle className="h-4 w-4 text-white" />
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-[11px] font-semibold text-white truncate leading-tight">
                {user?.email?.split('@')[0]}
              </p>
              <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#71717A] leading-tight">
                {role === 'accountant' ? (
                  'Accountant'
                ) : (
                  (role || 'Staff').toUpperCase()
                )}
              </p>
            </div>
          </div>

          <div className="border-t border-[#2E2E42] pt-1.5">
            <ChangePasswordSection />

            <button
              onClick={() => { signOut(); onItemClick?.(); }}
              className="flex min-h-8 w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-[11px] font-semibold text-[#71717A] hover:bg-white/[0.03] hover:text-white transition-all duration-150 border border-transparent group focus-visible:outline-white"
              aria-label="Sign out"
            >
              <LogOut className="h-3 w-3" />
              <span className="uppercase tracking-[0.12em]">Sign Out</span>
            </button>
          </div>
        </div>
      </div>
    </aside>

  );
}

function ChangePasswordSection() {
  const [open, setOpen] = useState(false);
  const [pw, setPw] = useState('');
  const [confirmPw, setConfirmPw] = useState('');
  const [loading, setLoading] = useState(false);
  const [done, setDone] = useState(false);
  const { toast } = useToast();

  const handleSubmit = async () => {
    if (pw.length < 6) {
      toast({ variant: 'destructive', title: 'Error', description: 'Password must be at least 6 characters' });
      return;
    }
    if (pw !== confirmPw) {
      toast({ variant: 'destructive', title: 'Error', description: 'Passwords do not match' });
      return;
    }
    setLoading(true);
    try {
      const { error } = await supabase.auth.updateUser({ password: pw });
      if (error) {
        toast({ variant: 'destructive', title: 'Error', description: error.message });
      } else {
        setDone(true);
        toast({ title: 'Success', description: 'Password changed successfully' });
        setTimeout(() => { setOpen(false); setDone(false); setPw(''); setConfirmPw(''); }, 2000);
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="mb-0.5">
      <button
        onClick={() => { setOpen(!open); setDone(false); setPw(''); setConfirmPw(''); }}
        className="flex min-h-8 w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-[11px] font-semibold text-[#71717A] hover:bg-white/[0.03] hover:text-white transition-all duration-150 group focus-visible:outline-white"
        aria-expanded={open}
      >
        <KeyRound className="h-3 w-3" />
        <span className="uppercase tracking-[0.12em]">{open ? 'Cancel' : 'Change Password'}</span>
      </button>

      {open && (
        <div className="px-1 py-2 space-y-1.5 animate-in fade-in slide-in-from-top-2 duration-200">
          {done ? (
            <div className="flex items-center gap-2 rounded-md bg-emerald-950/30 px-2.5 py-1.5">
              <CheckCircle2 className="h-3.5 w-3.5 text-emerald-400" />
              <span className="text-[10px] font-semibold text-emerald-400 uppercase tracking-widest">Updated!</span>
            </div>
          ) : (
            <>
              <input
                type="password"
                placeholder="New password"
                value={pw}
                onChange={e => setPw(e.target.value)}
                className="w-full h-8 rounded-md px-2.5 text-[11px] bg-[var(--color-sidebar-bg)] border border-[#2E2E42] text-white placeholder:text-[#71717A] font-semibold focus:outline-none focus:border-[var(--color-primary)]"
                aria-label="New password"
              />
              <input
                type="password"
                placeholder="Confirm password"
                value={confirmPw}
                onChange={e => setConfirmPw(e.target.value)}
                className="w-full h-8 rounded-md px-2.5 text-[11px] bg-[var(--color-sidebar-bg)] border border-[#2E2E42] text-white placeholder:text-[#71717A] font-semibold focus:outline-none focus:border-[var(--color-primary)]"
                aria-label="Confirm new password"
              />
              <button
                onClick={handleSubmit}
                disabled={loading}
                className="w-full h-8 rounded-md bg-[var(--color-primary)] hover:bg-[var(--color-transfer)] text-white text-[10px] font-semibold uppercase tracking-widest transition-all disabled:opacity-50 flex items-center justify-center gap-2 focus-visible:outline-white"
              >
                {loading ? <Loader2 className="h-3 w-3 animate-spin" /> : <KeyRound className="h-3 w-3" />}
                {loading ? 'Saving...' : 'Update'}
              </button>
            </>
          )}
        </div>
      )}
    </div>
  );
}
