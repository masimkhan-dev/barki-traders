/**
 * Vite environment variables for this client instance.
 * Values come from `.env` (see `.env.example`).
 */
function requireEnv(name: keyof ImportMetaEnv): string {
  const value = import.meta.env[name]?.trim();
  if (!value) {
    throw new Error(
      `Missing ${name}. Copy .env.example to .env and add Barki Traders Supabase credentials (Dashboard → Project Settings → API).`
    );
  }
  return value;
}

export const env = {
  supabaseUrl: requireEnv('VITE_SUPABASE_URL'),
  supabaseAnonKey: requireEnv('VITE_SUPABASE_ANON_KEY'),
  /** Isolates auth sessions when multiple client copies run on the same machine/browser */
  clientSlug: import.meta.env.VITE_CLIENT_SLUG?.trim() || 'barki-traders',
  appEnv: import.meta.env.VITE_APP_ENV?.trim() || 'development',
} as const;

export function getAuthStorageKey(): string {
  return `fdms-auth-${env.clientSlug}`;
}
