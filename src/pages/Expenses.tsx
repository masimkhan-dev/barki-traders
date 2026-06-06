
import { useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useToast } from '@/hooks/use-toast';
import { toastEditDeleteDisabled } from '@/lib/phase1-readonly';

export default function ExpensesRedirect() {
    const navigate = useNavigate();
    const [searchParams] = useSearchParams();
    const { toast } = useToast();

    useEffect(() => {
        if (searchParams.get('edit')) {
            toastEditDeleteDisabled(toast);
            navigate('/manage-transactions', { replace: true });
            return;
        }

        const query = searchParams.toString();
        navigate(`/manage-transactions${query ? '?' + query : ''}`, { replace: true });
    }, [navigate, searchParams, toast]);

    return (
        <div className="min-h-screen flex items-center justify-center bg-slate-50">
            <div className="text-center">
                <div className="h-8 w-8 border-4 border-slate-900 border-t-transparent animate-spin mx-auto mb-4"></div>
                <p className="text-[10px] font-black uppercase tracking-widest text-slate-400">
                    Redirecting to Transactions...
                </p>
            </div>
        </div>
    );
}
