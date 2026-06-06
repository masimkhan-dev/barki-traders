/** Session debug logging — remove after bug is verified fixed */
export function debugLog(
    location: string,
    message: string,
    data: Record<string, unknown>,
    hypothesisId: string,
    runId = 'pre-fix'
) {
    // #region agent log
    const debugCollectorEnabled =
        import.meta.env.DEV &&
        typeof window !== 'undefined' &&
        window.localStorage.getItem('FDMS_DEBUG_LOGS') === '1';

    if (!debugCollectorEnabled) return;

    fetch('http://127.0.0.1:7284/ingest/fd6c3250-5eda-4f67-ba27-30940ba8e03e', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Debug-Session-Id': 'decee1' },
        body: JSON.stringify({
            sessionId: 'decee1',
            location,
            message,
            data,
            hypothesisId,
            runId,
            timestamp: Date.now(),
        }),
    }).catch(() => {});
    // #endregion
}
