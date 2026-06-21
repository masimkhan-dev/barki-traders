/**
 * White-label client configuration — single source of truth for branding.
 * Update this file when onboarding a new client instance.
 */
export const clientConfig = {
  BUSINESS_NAME: 'Barki Traders',
  BUSINESS_TAGLINE: 'Fuel Supply & Distribution',
  BUSINESS_ADDRESS: 'Main G.T Road Opp Union Office Near PSO Depot Taru Jabba',
  BUSINESS_PHONE: 'Cell: 0310-9771002 | Barki Traders: 0334-9135464',
  BUSINESS_EMAIL: 'iftikharmehtab321@gmail.com',
  CURRENCY: 'PKR',
  LOCALE: 'en-PK',
  PRIMARY_COLOR: '#0f766e',
  LOGO_TEXT: 'BARKI TRADERS',
  TAGLINE: 'Audit Ledger System',
  LOGO_PATH: '/logo.svg',
} as const;

export const {
  BUSINESS_NAME,
  BUSINESS_TAGLINE,
  BUSINESS_ADDRESS,
  BUSINESS_PHONE,
  BUSINESS_EMAIL,
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
