import { Button } from '@/components/ui/button';
import { Printer, Download } from 'lucide-react';
import { exportToCSV, handlePrint } from '@/lib/export-utils';

interface ReportActionsProps {
    data: any[];
    filename: string;
    onPrint?: () => void;
    onExport?: () => void;
}

export const ReportActions = ({
    data,
    filename,
    onPrint = handlePrint,
    onExport
}: ReportActionsProps) => {
    const handleExport = () => {
        if (onExport) {
            onExport();
        } else {
            exportToCSV(data, filename);
        }
    };

    return (
        <div className="flex gap-2 print:hidden">
            <Button
                variant="outline"
                size="sm"
                onClick={onPrint}
                className="h-9 px-4 rounded-xl border-slate-200 bg-white hover:bg-slate-50 text-slate-900 font-black uppercase text-[10px] tracking-widest gap-2 shadow-sm transition-all active:scale-95"
            >
                <Printer className="h-4 w-4" />
                Print
            </Button>
            <Button
                variant="outline"
                size="sm"
                onClick={handleExport}
                className="h-9 px-4 rounded-xl border-slate-200 bg-white hover:bg-slate-50 text-emerald-700 font-black uppercase text-[10px] tracking-widest gap-2 shadow-sm transition-all active:scale-95"
            >
                <Download className="h-4 w-4" />
                Export CSV
            </Button>
        </div>
    );
};
