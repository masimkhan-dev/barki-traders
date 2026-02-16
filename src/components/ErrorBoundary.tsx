import React from 'react';

interface ErrorBoundaryState {
    hasError: boolean;
    error: Error | null;
}

interface ErrorBoundaryProps {
    children: React.ReactNode;
    fallback?: React.ReactNode;
}

/**
 * React Error Boundary — catches JavaScript errors in child components
 * and prevents the entire app from crashing.
 * 
 * Usage in App.tsx:
 *   <ErrorBoundary>
 *     <SomePageComponent />
 *   </ErrorBoundary>
 */
export class ErrorBoundary extends React.Component<ErrorBoundaryProps, ErrorBoundaryState> {
    constructor(props: ErrorBoundaryProps) {
        super(props);
        this.state = { hasError: false, error: null };
    }

    static getDerivedStateFromError(error: Error): ErrorBoundaryState {
        return { hasError: true, error };
    }

    componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
        // Log error details (replace with Sentry in production)
        console.error('[ErrorBoundary] Caught error:', error.message);
        console.error('[ErrorBoundary] Component stack:', errorInfo.componentStack);
    }

    render() {
        if (this.state.hasError) {
            if (this.props.fallback) {
                return this.props.fallback;
            }

            return (
                <div className="min-h-[400px] flex flex-col items-center justify-center p-8 text-center">
                    <div className="border-2 border-rose-200 bg-rose-50 p-8 max-w-md w-full">
                        <div className="text-[9px] font-black uppercase tracking-[0.3em] text-rose-400 mb-4">
                            System Error
                        </div>
                        <h2 className="text-lg font-black text-slate-900 uppercase tracking-tight mb-2">
                            Module Failed to Load
                        </h2>
                        <p className="text-xs text-slate-600 font-medium mb-6 leading-relaxed">
                            An unexpected error occurred in this section. Your data is safe.
                            Try refreshing the page or navigating to another section.
                        </p>
                        <div className="flex gap-3 justify-center">
                            <button
                                onClick={() => window.location.reload()}
                                className="px-6 py-2.5 bg-slate-900 text-white text-[10px] font-black uppercase tracking-widest hover:bg-black transition-colors"
                            >
                                Reload Page
                            </button>
                            <button
                                onClick={() => this.setState({ hasError: false, error: null })}
                                className="px-6 py-2.5 border-2 border-slate-300 text-slate-700 text-[10px] font-black uppercase tracking-widest hover:bg-slate-50 transition-colors"
                            >
                                Try Again
                            </button>
                        </div>
                        {this.state.error && (
                            <details className="mt-6 text-left">
                                <summary className="text-[9px] font-black uppercase text-slate-400 cursor-pointer tracking-widest">
                                    Technical Details
                                </summary>
                                <pre className="mt-2 text-[10px] text-rose-700 bg-rose-100 p-3 overflow-auto max-h-32 font-mono border border-rose-200">
                                    {this.state.error.message}
                                </pre>
                            </details>
                        )}
                    </div>
                </div>
            );
        }

        return this.props.children;
    }
}
