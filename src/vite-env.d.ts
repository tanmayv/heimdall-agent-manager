/// <reference types="vite/client" />

interface OdinApiRequestOptions {
  url: string;
  method?: string;
  body?: unknown;
}

interface Window {
  odinApi?: {
    request: (options: OdinApiRequestOptions) => Promise<unknown>;
  };
}
