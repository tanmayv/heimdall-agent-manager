export function artifactExtensionForMime(mime: string): string {
  const normalized = String(mime || '').toLowerCase();
  if (normalized === 'image/png') return '.png';
  if (normalized === 'image/jpeg') return '.jpg';
  if (normalized === 'image/gif') return '.gif';
  if (normalized === 'image/webp') return '.webp';
  if (normalized === 'text/markdown') return '.md';
  if (normalized === 'text/csv') return '.csv';
  if (normalized === 'text/html') return '.html';
  if (normalized === 'application/json') return '.json';
  if (normalized.startsWith('text/')) return '.txt';
  return '';
}

export function artifactUploadName(file: File, prefix = 'artifact'): string {
  const explicit = String(file?.name || '').trim();
  if (explicit) return explicit.replace(/[\\/\r\n\t]/g, '_');
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  return `${prefix}-${stamp}${artifactExtensionForMime(String(file?.type || '')) || '.bin'}`;
}

export function artifactKindForFile(file: File): string {
  const name = artifactUploadName(file).toLowerCase();
  const mime = String(file?.type || '').toLowerCase();
  if (mime.startsWith('image/')) return 'image';
  if (mime === 'text/markdown' || name.endsWith('.md') || name.endsWith('.markdown')) return 'markdown';
  if (mime === 'text/csv' || name.endsWith('.csv')) return 'csv';
  if (mime === 'text/html' || name.endsWith('.html') || name.endsWith('.htm')) return 'html';
  if (mime === 'application/json' || name.endsWith('.json')) return 'json';
  if (mime.startsWith('text/')) return 'text';
  return 'file';
}

export function artifactMimeForFile(file: File): string {
  return String(file?.type || '').trim() || 'application/octet-stream';
}

export function clipboardFilesFromEvent(event: any): File[] {
  const data = event?.clipboardData;
  const out: File[] = [];
  const seen = new Set<string>();
  const push = (file: File | null | undefined) => {
    if (!file) return;
    const key = [file.name || '', file.type || '', file.size || 0, file.lastModified || 0].join(':');
    if (seen.has(key)) return;
    seen.add(key);
    out.push(file);
  };
  Array.from(data?.files || []).forEach((file) => push(file as File));
  Array.from(data?.items || []).forEach((item: any) => {
    if (item?.kind === 'file' || String(item?.type || '').startsWith('image/')) push(item?.getAsFile?.() || null);
  });
  return out;
}

export function artifactLinkFromResponse(response: any): string {
  const artifact = response?.artifact || response?.data?.artifact || response?.data || response || {};
  const explicit = String(response?.link || artifact?.link || '').trim();
  if (explicit) return explicit;
  const id = String(artifact?.artifact_id || artifact?.artifactId || artifact?.id || '').trim();
  return id ? `artifact://${id}` : '';
}

export function artifactIdFromLink(value: string): string {
  return String(value || '').replace(/^artifact:\/\//i, '').trim();
}

export function artifactIdsFromText(value: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  const re = /artifact:\/\/([A-Za-z0-9._:-]+)/g;
  let match: RegExpExecArray | null;
  while ((match = re.exec(String(value || ''))) !== null) {
    const id = artifactIdFromLink(match[1]).replace(/[),.;:!?]+$/g, '');
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

export function appendArtifactLinks(body: string, links: string[]): string {
  const cleanLinks = links.map((link) => String(link || '').trim()).filter(Boolean);
  if (!cleanLinks.length) return body;
  const prefix = String(body || '').replace(/\s+$/, '');
  return prefix ? `${prefix}\n${cleanLinks.join('\n')}` : cleanLinks.join('\n');
}
