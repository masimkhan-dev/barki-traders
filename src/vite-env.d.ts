/// <reference types="vite/client" />

interface ImportMetaEnv {
    readonly VITE_SUPABASE_URL: string
    readonly VITE_SUPABASE_ANON_KEY: string
    /** Unique slug per client instance — keeps Supabase auth separate in the browser */
    readonly VITE_CLIENT_SLUG?: string
    readonly VITE_APP_ENV?: string
}

interface ImportMeta {
    readonly env: ImportMetaEnv
}
