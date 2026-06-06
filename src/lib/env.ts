/**
 * Vite environment variables for this client instance.
 * Local development reads `.env`; production must inject these in Vercel.
 */
function requireEnv(name: keyof ImportMetaEnv): string {
  const value = import.meta.env[name]?.trim();
  if (!value) {
    throw new Error(
      `Missing ${name}. Set it locally in .env or in Vercel Project Settings -> Environment Variables before deploying.`,
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
