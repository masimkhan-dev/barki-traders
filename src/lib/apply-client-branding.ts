import { clientConfig, getPageTitle } from '@/lib/client-config';

/** Apply document title and meta tags from client-config (Vite index.html is static). */
export function applyClientBranding(): void {
  const title = getPageTitle();
  document.title = title;

  const description = `${clientConfig.BUSINESS_NAME} — Professional Enterprise Audit & Ledger System`;

  const setMeta = (selector: string, content: string) => {
    const el = document.querySelector(selector);
    if (el) el.setAttribute('content', content);
  };

  setMeta('meta[name="description"]', description);
  setMeta('meta[name="author"]', clientConfig.BUSINESS_NAME);
  setMeta('meta[property="og:title"]', title);
  setMeta('meta[name="theme-color"]', clientConfig.PRIMARY_COLOR);
}
