import { createRoot } from 'react-dom/client';
import App from './App.tsx';
import './index.css';
import { applyClientBranding } from '@/lib/apply-client-branding';

applyClientBranding();

const walletNoisePattern =
  /MetaMask|ethereum|inpage\.js|contentscript\.js|Failed to connect to MetaMask|MetaMask extension not found/i;

const stringifyErrorParts = (value: unknown): string => {
  if (!value) return '';
  if (typeof value === 'string') return value;

  if (typeof value === 'object') {
    const record = value as {
      message?: unknown;
      stack?: unknown;
      reason?: { message?: unknown; stack?: unknown };
      cause?: { message?: unknown; stack?: unknown };
    };

    return [
      record.message,
      record.stack,
      record.reason?.message,
      record.reason?.stack,
      record.cause?.message,
      record.cause?.stack,
    ]
      .filter(Boolean)
      .map(String)
      .join(' ');
  }

  return String(value);
};

const isWalletExtensionNoise = (...values: unknown[]) =>
  values.some(value => walletNoisePattern.test(stringifyErrorParts(value)));

window.addEventListener(
  'error',
  event => {
    if (isWalletExtensionNoise(event.error, event.message, event.filename)) {
      event.preventDefault();
    }
  },
  true
);

window.addEventListener(
  'unhandledrejection',
  event => {
    if (isWalletExtensionNoise(event.reason)) {
      event.preventDefault();
    }
  },
  true
);

createRoot(document.getElementById('root')!).render(<App />);
