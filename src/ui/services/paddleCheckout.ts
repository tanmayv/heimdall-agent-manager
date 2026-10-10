// Load Paddle only when a user starts checkout. Server-created transactions
// carry account correlation; the browser never supplies a tier or account ID.
interface PaddleEvent { name: string }
interface PaddleSdk {
  Environment: { set: (environment: 'sandbox') => void };
  Initialize: (options: { token: string; eventCallback: (event: PaddleEvent) => void }) => void;
  Checkout: { open: (options: { transactionId: string; settings: { displayMode: 'overlay'; theme: 'dark' | 'light' } }) => void };
}
let loading: Promise<PaddleSdk> | undefined;
let initializedFor: string | undefined;
let completedHandler: (() => void) | undefined;

function loadPaddle(): Promise<PaddleSdk> {
  if (loading) return loading;
  loading = new Promise<PaddleSdk>((resolve, reject) => {
    const existing = (window as unknown as { Paddle?: PaddleSdk }).Paddle;
    if (existing) { resolve(existing); return; }
    const script = document.createElement('script');
    script.src = 'https://cdn.paddle.com/paddle/v2/paddle.js';
    script.async = true;
    const timer = setTimeout(() => fail(), 15000);
    function fail() {
      clearTimeout(timer);
      script.remove();
      loading = undefined;
      reject(new Error('Could not load checkout. Please try again.'));
    }
    script.onerror = fail;
    script.onload = () => {
      clearTimeout(timer);
      const sdk = (window as unknown as { Paddle?: PaddleSdk }).Paddle;
      if (sdk) resolve(sdk); else fail();
    };
    document.head.append(script);
  });
  return loading;
}

export function clearPaddleCheckoutHandler(): void { completedHandler = undefined; }

export async function openPaddleCheckout(options: {
  transactionId: string;
  clientToken: string;
  environment: 'sandbox' | 'live';
  theme: 'dark' | 'light';
  onCompleted: () => void;
  signal?: AbortSignal;
}): Promise<void> {
  if (!/^txn_[a-z0-9]+$/.test(options.transactionId) || !options.clientToken) throw new Error('Checkout is not configured.');
  if (options.signal?.aborted) throw new DOMException('Checkout cancelled.', 'AbortError');
  const sdk = await loadPaddle();
  if (options.signal?.aborted) throw new DOMException('Checkout cancelled.', 'AbortError');
  const binding = `${options.environment}:${options.clientToken}`;
  if (initializedFor && initializedFor !== binding) throw new Error('Billing configuration changed. Refresh the page to continue.');
  if (!initializedFor) {
    if (options.environment === 'sandbox') sdk.Environment.set('sandbox');
    sdk.Initialize({ token: options.clientToken, eventCallback: (event) => { if (event.name === 'checkout.completed') completedHandler?.(); } });
    initializedFor = binding;
  }
  completedHandler = options.onCompleted;
  sdk.Checkout.open({ transactionId: options.transactionId, settings: { displayMode: 'overlay', theme: options.theme } });
}

export function validatePortalUrl(value: string): string {
  const url = new URL(value);
  if (url.protocol !== 'https:' || !['customer-portal.paddle.com', 'sandbox-customer-portal.paddle.com'].includes(url.hostname) || url.username || url.password || url.port) throw new Error('Invalid subscription management link.');
  return url.href;
}
