import { useEffect } from 'react';
import { useNavigate } from 'react-router-dom';

export default function SalesRedirect() {
    const navigate = useNavigate();

    useEffect(() => {
        navigate('/manage-transactions?type=SALE', { replace: true });
    }, [navigate]);

    return (
        <div className="min-h-screen flex items-center justify-center bg-slate-50">
            <div className="text-center">
                <div className="h-8 w-8 border-4 border-slate-900 border-t-transparent animate-spin mx-auto mb-4"></div>
                <p className="text-[10px] font-black uppercase tracking-widest text-slate-400">
                    Opening Sales Terminal...
                </p>
            </div>
        </div>
    );
}
