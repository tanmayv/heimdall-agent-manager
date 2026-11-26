import base from '../../../vite.config.js';

export default {
  ...base,
  cacheDir: process.env.HOME_VITE_CACHE,
  server: {
    host: '127.0.0.1',
    port: Number(process.env.HOME_UI_PORT || 5196),
    strictPort: true,
    proxy: { '/api/v1': { target: process.env.HOME_HUB_ORIGIN || 'http://127.0.0.1:5197' } },
  },
};
