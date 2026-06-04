/**
 * White-label client configuration — single source of truth for branding.
 * Update this file when onboarding a new client instance.
 */
export const clientConfig = {
  BUSINESS_NAME: 'Barki Traders',
  CURRENCY: 'PKR',
  LOCALE: 'en-PK',
  PRIMARY_COLOR: '#0f766e',
  LOGO_TEXT: 'BARKI TRADERS',
  TAGLINE: 'Audit Ledger System',
  LOGO_PATH: '/logo.svg',
} as const;

export const {
  BUSINESS_NAME,
  CURRENCY,
  LOCALE,
  PRIMARY_COLOR,
  LOGO_TEXT,
} = clientConfig;

export type ClientConfig = typeof clientConfig;

/** Split LOGO_TEXT into primary / secondary lines for stacked sidebar & auth headers. */
export function getLogoLines(): { primary: string; secondary: string } {
  const parts = clientConfig.LOGO_TEXT.trim().split(/\s+/);
  if (parts.length <= 1) {
    return { primary: parts[0] ?? clientConfig.LOGO_TEXT, secondary: '' };
  }
  return { primary: parts[0], secondary: parts.slice(1).join(' ') };
}

export function getCopyrightText(year = new Date().getFullYear()): string {
  return `© ${year} ${clientConfig.BUSINESS_NAME} Enterprise.`;
}

export function getPageTitle(): string {
  return `${clientConfig.BUSINESS_NAME} | ${clientConfig.TAGLINE}`;
}

export function getPrintHeaderTitle(): string {
  return clientConfig.LOGO_TEXT;
}
