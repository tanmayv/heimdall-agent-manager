// Shiki's grammar/theme data lives in @shikijs/langs/<lang> and
// @shikijs/themes/<theme>. Those packages export the subpaths at runtime and for
// Vite/Rollup, but ship no per-subpath type declarations, so declare them as
// opaque default-exporting modules for TS. Runtime shape is validated by Shiki's
// own loadLanguage/theme APIs.
declare module '@shikijs/langs/*' {
  import type { LanguageRegistration } from 'shiki/core';
  const lang: LanguageRegistration[];
  export default lang;
}

declare module '@shikijs/themes/*' {
  import type { ThemeRegistration } from 'shiki/core';
  const theme: ThemeRegistration;
  export default theme;
}
