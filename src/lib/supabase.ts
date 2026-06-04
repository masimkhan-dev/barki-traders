import { createClient } from '@supabase/supabase-js';
import type { Database } from '@/integrations/supabase/types';
import { env, getAuthStorageKey } from '@/lib/env';

const supabaseUrl = env.supabaseUrl;
const supabaseAnonKey = env.supabaseAnonKey;

// ─── Token Refresh De-duplication ────────────────────────────────────────────
// Problem: Supabase uses single-use refresh tokens (rotation). If two concurrent
// calls both try to refresh, the second one uses an already-rotated token and
// gets a 429 / session invalidation → instant logout.
//
// Fix: Serialise all refresh_token requests so only ONE hits the network.
// Every other concurrent caller waits on the same in-flight promise.
// In browsers with Web Locks API (secure contexts), this is also coordinated
// across browser tabs so only one tab refreshes at a time.

const originalFetch = globalThis.fetch.bind(globalThis);
let activeRefreshPromise: Promise<Response> | null = null;

const guardedFetch: typeof fetch = (input, init) => {
  const url =
    typeof input === 'string'
      ? input
      : input instanceof URL
        ? input.href
        : (input as Request).url;

  // Only intercept token refresh calls
  if (!url.includes('grant_type=refresh_token')) {
    return originalFetch(input, init);
  }

  // ── Strategy A: Web Locks API (Chrome/Edge/Firefox — secure contexts only) ──
  // Acquires a tab-exclusive mutex so only one tab does the network refresh.
  if (
    typeof navigator !== 'undefined' &&
    navigator.locks &&
    typeof navigator.locks.acquire === 'function'
  ) {
    return navigator.locks.acquire('supabase-token-refresh', () =>
      originalFetch(input, init)
    );
  }

  // ── Strategy B: In-memory promise dedup (same tab, all browsers) ──
  // If a refresh is already in-flight, share its response clone.
  if (activeRefreshPromise) {
    return activeRefreshPromise.then((res) => res.clone());
  }

  activeRefreshPromise = originalFetch(input, init).then(
    (res) => { activeRefreshPromise = null; return res; },
    (err) => { activeRefreshPromise = null; throw err; }
  );

  return activeRefreshPromise.then((res) => res.clone());
};

// ─── Supabase Singleton ───────────────────────────────────────────────────────
// Vite HMR re-executes modules on every file save, which would create a new
// GoTrueClient each time → "Multiple GoTrueClient instances" warning + 429s.
// We cache the singleton on `globalThis` so HMR reloads reuse the same instance.

declare global {
  // eslint-disable-next-line no-var
  var __supabase_singleton__: ReturnType<typeof createClient<Database>> | undefined;
}

if (!globalThis.__supabase_singleton__) {
  globalThis.__supabase_singleton__ = createClient<Database>(supabaseUrl, supabaseAnonKey, {
    auth: {
      autoRefreshToken: true,
      persistSession: true,
      detectSessionInUrl: true,
      storageKey: getAuthStorageKey(),
      debug: false,
    },
    global: {
      fetch: guardedFetch,
    },
  });
}

export const supabase = globalThis.__supabase_singleton__;
