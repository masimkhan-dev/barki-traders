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
  CheckCircle2
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { cn } from '@/lib/utils';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';

interface NavItem {
  label: string;
  href: string;
  icon: React.ElementType;
  roles?: ('admin' | 'accountant')[];
}

const navItems: NavItem[] = [
  { label: 'Audit Terminal', href: '/dashboard', icon: LayoutDashboard },
  { label: 'Daily Diary (Roznamcha)', href: '/roznamcha', icon: CalendarDays, roles: ['admin', 'accountant'] },
  { label: 'Daily Book V3 (New)', href: '/roznamcha-v3', icon: CalendarDays, roles: ['admin', 'accountant'] },
  { label: 'Voucher Factory', href: '/manage-transactions', icon: ArrowRightLeft, roles: ['admin', 'accountant'] },
  { label: 'Manage Accounts (COA)', href: '/settings/coa', icon: Building2, roles: ['admin', 'accountant'] },
  { label: 'Expense Register', href: '/expenses', icon: Receipt, roles: ['admin', 'accountant'] },
  { label: 'Physical Stock Audit', href: '/inventory', icon: Package },
  { label: 'Party Statement', href: '/reports/account-statement', icon: FileText },
  { label: 'Market Position (Lena/Dena)', href: '/reports/business', icon: BarChart3 },
  { label: 'Income Statement (P&L)', href: '/reports/profit-loss', icon: Receipt },
  { label: 'Trial Balance', href: '/reports/trial-balance', icon: Wallet },
  { label: 'Statement of Condition (BS)', href: '/reports/balance-sheet', icon: FileMinus },
  { label: 'Month-End Seal (Coming Soon)', href: '/month-end-closing', icon: Lock, roles: ['admin'] },
  { label: 'Proprietor Statement (Coming Soon)', href: '/reports/capital', icon: UserCircle2, roles: ['admin'] },
  { label: 'Khata Search (Ledger)', href: '/ledger', icon: BookOpen },
  { label: 'Access Control', href: '/users', icon: UserCircle, roles: ['admin'] },
];


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
    if (!item.roles) return true;
    return role && item.roles.includes(role);
  });

  const isFixed = className?.includes('fixed') || (!className?.includes('relative') && !className?.includes('static'));

  return (

    <aside className={cn(
      isFixed ? "fixed left-0 top-0 z-40 h-screen w-72 bg-slate-950 border-r border-slate-800" : "w-full h-full bg-slate-950",
      className
    )}>
      <div className="flex flex-col h-full">
        {/* BRANDING SECTION */}
        <div className="p-8 border-b border-white/5">
          <Link to="/" onClick={onItemClick} className="flex flex-col gap-1">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-none bg-slate-900 border border-white/10 overflow-hidden p-1.5">
                <img src="/logo.svg" alt="Naveed Musazai" className="h-full w-full object-contain filter brightness-110" />
              </div>
              <h1 className="text-xl font-black text-white tracking-tighter leading-none uppercase">
                NAVEED <br /> <span className="text-slate-500">MUSAZAI</span>
              </h1>
            </div>
            <p className="text-[9px] text-slate-600 font-black uppercase tracking-[0.4em] mt-4 pl-1">Audit Ledger System</p>
          </Link>
        </div>

        {/* NAVIGATION AREA */}
        <nav
          ref={navRef}
          onScroll={handleScroll}
          className="flex-1 space-y-0.5 px-3 py-6 overflow-y-auto scrollbar-none"
        >
          {filteredNavItems.map((item) => {
            const isActive = location.pathname === item.href;
            const Icon = item.icon;

            return (
              <Link
                key={item.href}
                to={item.href}
                onClick={onItemClick}
                className={cn(
                  'flex items-center gap-3 px-4 py-2.5 rounded-none transition-all duration-200 group mb-0.5 border-l-2',
                  isActive
                    ? 'bg-white/10 border-l-white text-white shadow-sm shadow-black/20'
                    : 'text-slate-500 border-l-transparent hover:bg-white/[0.07] hover:text-slate-200 hover:border-l-slate-600'
                )}
              >
                <Icon className={cn("h-4 w-4 flex-shrink-0 transition-colors duration-200", isActive ? "text-white" : "text-slate-600 group-hover:text-slate-400")} />
                <span className="font-bold text-[11px] uppercase tracking-wider leading-tight">{item.label}</span>
              </Link>
            );
          })}
        </nav>

        {/* USER PROFILE SECTION */}
        <div className="p-4 bg-slate-950/50 border-t border-white/5">
          <div className="flex items-center gap-3 p-3 rounded-none bg-white/5 border border-white/5 mb-3 px-4">
            <div className="flex h-8 w-8 items-center justify-center rounded-none bg-slate-800 shrink-0 border border-slate-700">
              <UserCircle className="h-5 w-5 text-slate-400" />
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-[10px] font-black text-slate-300 truncate uppercase tracking-tighter">
                {user?.email?.split('@')[0]}
              </p>
              <p className="text-[8px] font-black uppercase tracking-widest">
                {role === 'accountant' ? (
                  <span className="bg-emerald-900/50 text-emerald-400 px-1.5 py-0.5 border border-emerald-800/50">MUNSHI (ACCOUNTANT)</span>
                ) : (
                  <span className="bg-blue-900/50 text-blue-400 px-1.5 py-0.5 border border-blue-800/50">{(role || 'Staff').toUpperCase()}</span>
                )}
              </p>
            </div>
          </div>

          <ChangePasswordSection />

          <button
            onClick={() => { signOut(); onItemClick?.(); }}
            className="flex w-full items-center gap-3 rounded-none px-4 py-2.5 text-[10px] font-black text-rose-500 hover:bg-rose-950/30 hover:text-rose-400 transition-all duration-200 border border-transparent border-t-white/5 group"
          >
            <LogOut className="h-3.5 w-3.5" />
            <span className="uppercase tracking-[0.2em]">Terminate Session</span>
          </button>
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
    <div className="px-3 mb-2">
      <button
        onClick={() => { setOpen(!open); setDone(false); setPw(''); setConfirmPw(''); }}
        className="flex w-full items-center gap-3 rounded-none px-4 py-2 text-[10px] font-black text-slate-400 hover:bg-white/[0.07] hover:text-slate-200 transition-all duration-200 group"
      >
        <KeyRound className="h-3.5 w-3.5" />
        <span className="uppercase tracking-[0.2em]">{open ? 'Cancel' : 'Change Password'}</span>
      </button>

      {open && (
        <div className="px-4 py-3 space-y-2 animate-in fade-in slide-in-from-top-2 duration-200">
          {done ? (
            <div className="flex items-center gap-2 py-2">
              <CheckCircle2 className="h-4 w-4 text-emerald-400" />
              <span className="text-[10px] font-black text-emerald-400 uppercase tracking-widest">Updated!</span>
            </div>
          ) : (
            <>
              <input
                type="password"
                placeholder="New password"
                value={pw}
                onChange={e => setPw(e.target.value)}
                className="w-full h-8 px-3 text-xs bg-slate-800 border border-slate-700 text-white placeholder:text-slate-500 font-bold focus:outline-none focus:border-slate-500"
              />
              <input
                type="password"
                placeholder="Confirm password"
                value={confirmPw}
                onChange={e => setConfirmPw(e.target.value)}
                className="w-full h-8 px-3 text-xs bg-slate-800 border border-slate-700 text-white placeholder:text-slate-500 font-bold focus:outline-none focus:border-slate-500"
              />
              <button
                onClick={handleSubmit}
                disabled={loading}
                className="w-full h-8 bg-slate-700 hover:bg-slate-600 text-white text-[10px] font-black uppercase tracking-widest transition-all disabled:opacity-50 flex items-center justify-center gap-2"
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
