/// <reference types="vite/client" />

interface OdinApiRequestOptions {
  url: string;
  method?: string;
  body?: unknown;
}

interface OdinPickDirectoryResult {
  ok: boolean;
  canceled: boolean;
  path: string;
}

interface Window {
  odinApi?: {
    request: (options: OdinApiRequestOptions) => Promise<unknown>;
    pickDirectory?: () => Promise<OdinPickDirectoryResult>;
  };
}
