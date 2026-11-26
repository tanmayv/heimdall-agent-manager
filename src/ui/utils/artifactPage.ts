import { buildRouteHash, getRoutePathname } from './appLocation';

const ARTIFACT_PAGE_PREFIX = '/library/artifacts/';

export function artifactIdFromPath(path: string): string {
  const encoded = path.startsWith(ARTIFACT_PAGE_PREFIX) ? path.slice(ARTIFACT_PAGE_PREFIX.length).replace(/\/$/, '') : '';
  try {
    return decodeURIComponent(encoded);
  } catch {
    return '';
  }
}

function updateArtifactLocation(method: 'pushState' | 'replaceState', href: string, state: object | null): void {
  window.history[method](state, '', href);
  // pushState and replaceState don't emit a location event. Feed the same
  // route listener that handles actual browser back and forward traversals.
  window.dispatchEvent(new window.PopStateEvent('popstate', { state }));
}

export function openArtifactPage(artifactId: string): void {
  if (!artifactId || artifactIdFromPath(getRoutePathname()) === artifactId) return;
  updateArtifactLocation('pushState', buildRouteHash(ARTIFACT_PAGE_PREFIX + encodeURIComponent(artifactId), ''), { artifactPageBack: true });
}

export function closeArtifactPage(): void {
  if (window.history.state?.artifactPageBack === true) {
    window.history.back();
  } else {
    // A pasted or externally opened URL has no known in-app predecessor.
    updateArtifactLocation('replaceState', buildRouteHash('/library', ''), null);
  }
}

export function handleArtifactPageLink(event: MouseEvent): void {
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const link = event.target instanceof window.Element ? event.target.closest<HTMLAnchorElement>('a[href]') : null;
  if (!link || (link.target && link.target !== '_self') || link.hasAttribute('download')) return;
  const href = link.getAttribute('href');
  const id = href?.startsWith('#') ? artifactIdFromPath(href.slice(1)) : '';
  if (!id) return;
  event.preventDefault();
  openArtifactPage(id);
}
