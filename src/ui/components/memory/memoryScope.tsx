// Shared building blocks for the redesigned Memory surface (MemoryPage +
// MemoryDetailPage). Memory targeting is a LIST per dimension (T1 contract):
// agent_ids / project_ids / bridge_ids / template_ids, where an EMPTY list means
// "applies to all" for that dimension. The TS API exposes these as camelCase
// string[] (agentIds/projectIds/bridgeIds/templateIds); this module centralises
// the dimension metadata, the option catalogs, and the read-only scope chips so
// the page, detail, and proposal surfaces all render targeting consistently.

import { useMemo } from 'react';
import type { SearchableOption } from '../SearchableSelect';
import SearchableMultiSelect from '../SearchableMultiSelect';
import {
  useListAgentIdentitiesQuery,
  useListAgentTemplatesQuery,
} from '../../api/endpoints/agents';
import { useListSidebarProjectsQuery } from '../../api/endpoints/sidebar';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';

// Targeting is a fully-populated shape internally (each dimension is always an
// array; empty = all). Components spread this straight into the memory API.
export type Targeting = {
  agentIds: string[];
  projectIds: string[];
  bridgeIds: string[];
  templateIds: string[];
};

export type ScopeDimKey = keyof Targeting;

// Presentation metadata for each targeting dimension. Order matches the mock:
// Projects / Agents / Bridges / Templates. Chip colors are full Tailwind class
// strings (Tailwind can't compose class names at runtime) so each dimension is
// visually distinguishable when scanning mixed scope lists.
export const SCOPE_DIMS: {
  key: ScopeDimKey;
  label: string;
  allLabel: string;
  debug: string;
  chip: string;
}[] = [
  { key: 'projectIds', label: 'Projects', allLabel: 'All projects', debug: 'project', chip: 'border-emerald-400/30 bg-emerald-400/10 text-emerald-200' },
  { key: 'agentIds', label: 'Agents', allLabel: 'All agents', debug: 'agent', chip: 'border-sky-400/30 bg-sky-400/10 text-sky-200' },
  { key: 'bridgeIds', label: 'Bridges', allLabel: 'All bridges', debug: 'bridge', chip: 'border-violet-400/30 bg-violet-400/10 text-violet-200' },
  { key: 'templateIds', label: 'Templates', allLabel: 'All templates', debug: 'template', chip: 'border-amber-400/30 bg-amber-400/10 text-amber-200' },
];

export const MEMORY_TYPES = ['fact', 'habit', 'episode', 'expertise', 'skill'];

export function emptyTargeting(): Targeting {
  return { agentIds: [], projectIds: [], bridgeIds: [], templateIds: [] };
}

// Pull the targeting lists off a normalized memory record (memoryCatalog already
// exposes agentIds/projectIds/bridgeIds/templateIds as arrays).
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
export function targetingFromRecord(record: any): Targeting {
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const list = (value: any) => (Array.isArray(value) ? value.map((v: any) => String(v || '').trim()).filter(Boolean) : []);
  return {
    agentIds: list(record?.agentIds),
    projectIds: list(record?.projectIds),
    bridgeIds: list(record?.bridgeIds),
    templateIds: list(record?.templateIds),
  };
}

export type ScopeCatalogEntry = {
  options: SearchableOption[];
  loading: boolean;
  byId: Map<string, string>;
};

export type ScopeCatalog = Record<ScopeDimKey, ScopeCatalogEntry>;

function toEntry(rows: { id: string; name: string; subtitle?: string }[], loading: boolean): ScopeCatalogEntry {
  const options = rows.map((row) => ({ value: row.id, title: row.name, subtitle: row.subtitle, id: row.id }));
  const byId = new Map(rows.map((row) => [row.id, row.name]));
  return { options, loading, byId };
}

// useMemoryScopeCatalog loads the four option catalogs (agents/projects/bridges/
// templates) used by every scope control on the Memory surface. It mirrors the
// normalization the previous MemoryScopeSelector used, but exposes reusable
// SearchableOption lists + id→name lookups keyed by targeting dimension.
export function useMemoryScopeCatalog(): ScopeCatalog {
  const identitiesQuery = useListAgentIdentitiesQuery();
  const projectsQuery = useListSidebarProjectsQuery();
  const bridgesQuery = useListBridgesQuery();
  const templatesQuery = useListAgentTemplatesQuery();

  const agents = useMemo(() => {
    const raw = identitiesQuery.data?.agents;
    const list = Array.isArray(raw) ? raw : Array.isArray(identitiesQuery.data) ? (identitiesQuery.data as any[]) : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      .map((item: any) => ({ id: String(item.agent_id || item.agentId || item.id || ''), name: String(item.name || item.slug || item.agent_id || item.agentId || 'Unnamed agent') }))
      .filter((item) => Boolean(item.id));
  }, [identitiesQuery.data]);

  const projects = useMemo(() => {
    const list = Array.isArray(projectsQuery.data) ? projectsQuery.data : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      .map((item: any) => ({ id: String(item.projectId || item.project_id || item.id || ''), name: String(item.name || item.title || item.projectId || 'Unnamed project') }))
      .filter((item) => Boolean(item.id));
  }, [projectsQuery.data]);

  const bridges = useMemo(() => {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    const raw = (bridgesQuery.data as any)?.bridges || bridgesQuery.data || [];
    const list = Array.isArray(raw) ? raw : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      .map((item: any) => ({ id: String(item.bridge_id || item.bridgeId || item.id || ''), name: String(item.name || item.label || item.bridge_id || item.bridgeId || 'Unnamed bridge') }))
      .filter((item) => Boolean(item.id));
  }, [bridgesQuery.data]);

  const templates = useMemo(() => {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    const raw = (templatesQuery.data as any)?.templates || templatesQuery.data || [];
    const list = Array.isArray(raw) ? raw : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      .map((item: any) => ({ id: String(item.template_id || item.templateId || item.id || ''), name: String(item.name || item.title || item.template_id || 'Unnamed template') }))
      .filter((item) => Boolean(item.id));
  }, [templatesQuery.data]);

  return {
    agentIds: toEntry(agents, identitiesQuery.isLoading),
    projectIds: toEntry(projects, projectsQuery.isLoading),
    bridgeIds: toEntry(bridges, bridgesQuery.isLoading),
    templateIds: toEntry(templates, templatesQuery.isLoading),
  };
}

// ScopeChips renders a memory's targeting as read-only chips, one row per
// dimension, and explicitly shows "All …" for an empty dimension so the user
// understands empty ≠ none. Ids resolve to human names via the catalog when
// available, falling back to the raw id.
export function ScopeChips({ targeting, catalog, debugId }: { targeting: Targeting; catalog: ScopeCatalog; debugId: string }) {
  return (
    <div data-debug-id={debugId} className="flex flex-wrap gap-1.5">
      {SCOPE_DIMS.map((dim) => {
        const ids = targeting[dim.key];
        if (ids.length === 0) {
          return (
            <span key={dim.key} data-debug-id={`${debugId}-${dim.debug}-all`} className="inline-flex items-center rounded-full border border-white/10 bg-white/[0.03] px-2 py-0.5 text-[11px] text-zinc-500">
              {dim.allLabel}
            </span>
          );
        }
        return ids.map((id) => (
          <span key={`${dim.key}-${id}`} title={id} data-debug-id={`${debugId}-${dim.debug}-${id}`} className={`inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] ${dim.chip}`}>
            {catalog[dim.key].byId.get(id) || id}
          </span>
        ));
      })}
    </div>
  );
}

// ScopeEditor renders the four targeting dimensions as SearchableMultiSelect
// controls (empty = all). Shared by the create modal, proposal review, and the
// detail edit surface so scope editing behaves identically everywhere.
export function ScopeEditor({ targeting, catalog, onChange, debugId, disabled = false }: { targeting: Targeting; catalog: ScopeCatalog; onChange: (next: Targeting) => void; debugId: string; disabled?: boolean }) {
  return (
    <div data-debug-id={debugId} className="grid gap-3 sm:grid-cols-2">
      {SCOPE_DIMS.map((dim) => (
        <label key={dim.key} className="block">
          <div className="mb-1 text-[11px] uppercase tracking-wide text-zinc-500">{dim.label}</div>
          <SearchableMultiSelect
            options={catalog[dim.key].options}
            values={targeting[dim.key]}
            onChange={(next) => onChange({ ...targeting, [dim.key]: next })}
            debugId={`${debugId}-${dim.debug}`}
            allLabel={dim.allLabel}
            chipClassName={dim.chip}
            loading={catalog[dim.key].loading}
            disabled={disabled}
            placeholder={`Search ${dim.label.toLowerCase()}…`}
          />
        </label>
      ))}
    </div>
  );
}
