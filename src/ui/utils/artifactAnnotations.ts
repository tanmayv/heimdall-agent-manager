export const ARTIFACT_ANNOTATIONS_STORAGE_KEY = 'heimdall.artifact.annotations.v1';

type AnnotationStore = {
  version: 1;
  byArtifactId: Record<string, ArtifactAnnotationRecord[]>;
};

export type TextAnnotationContext = {
  type: 'text';
  lineStart?: number;
  lineEnd?: number;
  selectedText?: string;
  charStart?: number;
  charEnd?: number;
};

export type ImageAnnotationContext = {
  type: 'image';
  x: number;
  y: number;
  w: number;
  h: number;
  xPercent: number;
  yPercent: number;
  wPercent: number;
  hPercent: number;
  imageNaturalWidth?: number;
  imageNaturalHeight?: number;
};

export type ArtifactAnnotationContext = TextAnnotationContext | ImageAnnotationContext;

export type ArtifactAnnotationRecord = {
  annotationId: string;
  artifactId: string;
  artifactUri: string;
  artifactName: string;
  artifactMime: string;
  artifactKind: string;
  createdAt: number;
  updatedAt: number;
  comment: string;
  context: ArtifactAnnotationContext;
};

export type CreateArtifactAnnotationInput = Omit<ArtifactAnnotationRecord, 'annotationId' | 'createdAt' | 'updatedAt'> & {
  annotationId?: string;
  createdAt?: number;
  updatedAt?: number;
};

function defaultStore(): AnnotationStore {
  return { version: 1, byArtifactId: {} };
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function normalizeTextContext(value: unknown): TextAnnotationContext {
  const raw = isObject(value) ? value : {};
  return {
    type: 'text',
    lineStart: typeof raw.lineStart === 'number' ? raw.lineStart : undefined,
    lineEnd: typeof raw.lineEnd === 'number' ? raw.lineEnd : undefined,
    selectedText: typeof raw.selectedText === 'string' ? raw.selectedText : undefined,
    charStart: typeof raw.charStart === 'number' ? raw.charStart : undefined,
    charEnd: typeof raw.charEnd === 'number' ? raw.charEnd : undefined,
  };
}

function normalizeImageContext(value: unknown): ImageAnnotationContext {
  const raw = isObject(value) ? value : {};
  return {
    type: 'image',
    x: typeof raw.x === 'number' ? raw.x : 0,
    y: typeof raw.y === 'number' ? raw.y : 0,
    w: typeof raw.w === 'number' ? raw.w : 0,
    h: typeof raw.h === 'number' ? raw.h : 0,
    xPercent: typeof raw.xPercent === 'number' ? raw.xPercent : 0,
    yPercent: typeof raw.yPercent === 'number' ? raw.yPercent : 0,
    wPercent: typeof raw.wPercent === 'number' ? raw.wPercent : 0,
    hPercent: typeof raw.hPercent === 'number' ? raw.hPercent : 0,
    imageNaturalWidth: typeof raw.imageNaturalWidth === 'number' ? raw.imageNaturalWidth : undefined,
    imageNaturalHeight: typeof raw.imageNaturalHeight === 'number' ? raw.imageNaturalHeight : undefined,
  };
}

function normalizeContext(value: unknown): ArtifactAnnotationContext {
  const raw = isObject(value) ? value : {};
  return raw.type === 'image' ? normalizeImageContext(raw) : normalizeTextContext(raw);
}

function normalizeAnnotation(value: unknown): ArtifactAnnotationRecord | null {
  if (!isObject(value)) return null;
  const artifactId = typeof value.artifactId === 'string' ? value.artifactId : '';
  if (!artifactId) return null;
  const annotationId = typeof value.annotationId === 'string' && value.annotationId ? value.annotationId : createAnnotationId();
  const createdAt = typeof value.createdAt === 'number' ? value.createdAt : Date.now();
  const updatedAt = typeof value.updatedAt === 'number' ? value.updatedAt : createdAt;
  return {
    annotationId,
    artifactId,
    artifactUri: typeof value.artifactUri === 'string' && value.artifactUri ? value.artifactUri : buildArtifactUri(artifactId),
    artifactName: typeof value.artifactName === 'string' ? value.artifactName : artifactId,
    artifactMime: typeof value.artifactMime === 'string' ? value.artifactMime : '',
    artifactKind: typeof value.artifactKind === 'string' ? value.artifactKind : '',
    createdAt,
    updatedAt,
    comment: typeof value.comment === 'string' ? value.comment : '',
    context: normalizeContext(value.context),
  };
}

function loadStore(): AnnotationStore {
  if (typeof window === 'undefined' || !window.localStorage) return defaultStore();
  try {
    const raw = window.localStorage.getItem(ARTIFACT_ANNOTATIONS_STORAGE_KEY);
    if (!raw) return defaultStore();
    const parsed = JSON.parse(raw);
    if (!isObject(parsed)) return defaultStore();
    const byArtifactIdRaw = isObject(parsed.byArtifactId) ? parsed.byArtifactId : {};
    const byArtifactId: Record<string, ArtifactAnnotationRecord[]> = {};
    Object.entries(byArtifactIdRaw).forEach(([artifactId, annotations]) => {
      if (!Array.isArray(annotations)) return;
      byArtifactId[artifactId] = annotations
        .map((annotation) => normalizeAnnotation(annotation))
        .filter((annotation): annotation is ArtifactAnnotationRecord => Boolean(annotation))
        .sort((a, b) => a.createdAt - b.createdAt);
    });
    return { version: 1, byArtifactId };
  } catch {
    return defaultStore();
  }
}

function saveStore(store: AnnotationStore) {
  if (typeof window === 'undefined' || !window.localStorage) return;
  try {
    window.localStorage.setItem(ARTIFACT_ANNOTATIONS_STORAGE_KEY, JSON.stringify(store));
  } catch {
    // Ignore persistence failures so the viewer remains usable.
  }
}

export function buildArtifactUri(artifactId: string) {
  return artifactId ? `artifact://${artifactId}` : 'artifact://unknown';
}

export function createAnnotationId() {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return `annotation_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

export function createArtifactAnnotation(input: CreateArtifactAnnotationInput): ArtifactAnnotationRecord {
  const now = Date.now();
  const annotation = normalizeAnnotation({
    ...input,
    annotationId: input.annotationId || createAnnotationId(),
    createdAt: input.createdAt ?? now,
    updatedAt: input.updatedAt ?? now,
  });
  if (!annotation) {
    throw new Error('Artifact annotations require an artifactId.');
  }
  return annotation;
}

export function listArtifactAnnotations(artifactId: string): ArtifactAnnotationRecord[] {
  if (!artifactId) return [];
  const store = loadStore();
  return [...(store.byArtifactId[artifactId] || [])].sort((a, b) => a.createdAt - b.createdAt);
}

export function saveArtifactAnnotation(annotation: ArtifactAnnotationRecord): ArtifactAnnotationRecord[] {
  if (!annotation.artifactId) return [];
  const store = loadStore();
  const current = store.byArtifactId[annotation.artifactId] || [];
  const next = current.some((item) => item.annotationId === annotation.annotationId)
    ? current.map((item) => (item.annotationId === annotation.annotationId ? { ...annotation, updatedAt: Date.now() } : item))
    : [...current, annotation];
  store.byArtifactId[annotation.artifactId] = next.sort((a, b) => a.createdAt - b.createdAt);
  saveStore(store);
  return store.byArtifactId[annotation.artifactId];
}

export function updateArtifactAnnotationComment(artifactId: string, annotationId: string, comment: string): ArtifactAnnotationRecord[] {
  if (!artifactId || !annotationId) return listArtifactAnnotations(artifactId);
  const store = loadStore();
  const current = store.byArtifactId[artifactId] || [];
  store.byArtifactId[artifactId] = current.map((annotation) => (
    annotation.annotationId === annotationId
      ? { ...annotation, comment, updatedAt: Date.now() }
      : annotation
  ));
  saveStore(store);
  return store.byArtifactId[artifactId] || [];
}

export function removeArtifactAnnotation(artifactId: string, annotationId: string): ArtifactAnnotationRecord[] {
  if (!artifactId || !annotationId) return listArtifactAnnotations(artifactId);
  const store = loadStore();
  const current = store.byArtifactId[artifactId] || [];
  const next = current.filter((annotation) => annotation.annotationId !== annotationId);
  if (next.length > 0) {
    store.byArtifactId[artifactId] = next;
  } else {
    delete store.byArtifactId[artifactId];
  }
  saveStore(store);
  return next;
}

function formatNumber(value: number) {
  if (!Number.isFinite(value)) return '0';
  if (Math.abs(value - Math.round(value)) < 0.001) return String(Math.round(value));
  return value.toFixed(2).replace(/\.00$/, '').replace(/(\.\d)0$/, '$1');
}

function formatPercent(value: number) {
  if (!Number.isFinite(value)) return '0.0%';
  return `${value.toFixed(1)}%`;
}

function quoteSelection(value: string) {
  const trimmed = value.replace(/\s+/g, ' ').trim();
  if (!trimmed) return '';
  return `“${trimmed}”`;
}

export function summarizeAnnotationContext(annotation: ArtifactAnnotationRecord) {
  if (annotation.context.type === 'image') {
    return `Region x=${formatNumber(annotation.context.x)} y=${formatNumber(annotation.context.y)} w=${formatNumber(annotation.context.w)} h=${formatNumber(annotation.context.h)}`;
  }
  const parts: string[] = [];
  if (annotation.context.lineStart && annotation.context.lineEnd && annotation.context.lineStart !== annotation.context.lineEnd) {
    parts.push(`Lines ${annotation.context.lineStart}-${annotation.context.lineEnd}`);
  } else if (annotation.context.lineStart) {
    parts.push(`Line ${annotation.context.lineStart}`);
  }
  if (annotation.context.selectedText) {
    parts.push(quoteSelection(annotation.context.selectedText));
  }
  return parts.join(' · ') || 'Text selection';
}

export function formatAnnotationMarkdown(annotation: ArtifactAnnotationRecord) {
  const artifactName = annotation.artifactName || annotation.artifactId || 'Artifact';
  const artifactUri = annotation.artifactUri || buildArtifactUri(annotation.artifactId);
  const contextLines = [
    `- artifact: ${artifactUri}`,
    `- file: ${artifactName}`,
    `- type: ${annotation.artifactMime || annotation.artifactKind || 'artifact'}`,
  ];

  if (annotation.context.type === 'image') {
    contextLines.push(`- region: x=${formatNumber(annotation.context.x)} y=${formatNumber(annotation.context.y)} w=${formatNumber(annotation.context.w)} h=${formatNumber(annotation.context.h)}`);
    contextLines.push(`- region_percent: x=${formatPercent(annotation.context.xPercent)} y=${formatPercent(annotation.context.yPercent)} w=${formatPercent(annotation.context.wPercent)} h=${formatPercent(annotation.context.hPercent)}`);
  } else {
    if (annotation.context.lineStart && annotation.context.lineEnd && annotation.context.lineStart !== annotation.context.lineEnd) {
      contextLines.push(`- location: lines ${annotation.context.lineStart}-${annotation.context.lineEnd}`);
    } else if (annotation.context.lineStart) {
      contextLines.push(`- location: line ${annotation.context.lineStart}`);
    }
    if (annotation.context.selectedText) {
      contextLines.push(`- selection: ${quoteSelection(annotation.context.selectedText)}`);
    }
  }

  return [
    `Artifact annotation on [${artifactName}](${artifactUri})`,
    '',
    'Context:',
    ...contextLines,
    '',
    'Comment:',
    annotation.comment.trim() || '(empty comment)',
  ].join('\n');
}

export function formatAllAnnotationsMarkdown(annotations: ArtifactAnnotationRecord[]) {
  return annotations.map((annotation) => formatAnnotationMarkdown(annotation)).join('\n\n---\n\n');
}

export async function copyTextToClipboard(text: string) {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // Fall through to the textarea fallback; Electron/Chromium can expose the
      // Clipboard API while rejecting writes for permission/focus reasons.
    }
  }

  const textarea = document.createElement('textarea');
  try {
    textarea.value = text;
    textarea.setAttribute('readonly', '');
    textarea.style.position = 'fixed';
    textarea.style.left = '-9999px';
    textarea.style.opacity = '0';
    document.body.appendChild(textarea);
    textarea.select();
    if (!document.execCommand('copy')) {
      throw new Error('Copy command was not accepted');
    }
  } finally {
    textarea.remove();
  }
}
