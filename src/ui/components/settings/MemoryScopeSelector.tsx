import React, { useMemo } from "react";
import { Select } from "@ui";
import {
  useListAgentIdentitiesQuery,
  useListAgentTemplatesQuery,
} from "../../api/endpoints/agents";
import { useListSidebarProjectsQuery } from "../../api/endpoints/sidebar";
import { useListBridgesQuery } from "../../api/endpoints/bridgeSupport";

export type MemoryScopeValue = {
  agent_id?: string;
  project_id?: string;
  bridge_id?: string;
  template_id?: string;
  type?: string;
};

export type MemoryScopeSelectorProps = {
  value: MemoryScopeValue;
  onChange: (next: MemoryScopeValue) => void;
  readOnly?: boolean;
  disabled?: boolean;
  hideTypeSelect?: boolean;
  className?: string;
  debugPrefix?: string;
};

// COMPILE SHIM (memory list-scope migration): the memory API now targets LISTS
// (agentIds/projectIds/bridgeIds/templateIds), but this selector is still a
// single-value UI (the multi-select redesign is a later task). These helpers
// bridge the two: a single scalar scope maps to a 0/1-element list, and a list
// collapses to its first element for display/edit. Remove when the multi-select
// UI lands.
export type MemoryScopeLists = {
  agentIds?: string[];
  projectIds?: string[];
  bridgeIds?: string[];
  templateIds?: string[];
};

export function scopeToLists(scope: MemoryScopeValue): MemoryScopeLists {
  const one = (v?: string) => (v && v.trim() ? [v.trim()] : []);
  return {
    agentIds: one(scope.agent_id),
    projectIds: one(scope.project_id),
    bridgeIds: one(scope.bridge_id),
    templateIds: one(scope.template_id),
  };
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
export function listsToScope(record: any, type?: string): MemoryScopeValue {
  const first = (arr?: string[]) => (Array.isArray(arr) && arr.length ? arr[0] : undefined);
  return {
    agent_id: first(record?.agentIds) ?? record?.targetAgentId ?? undefined,
    project_id: first(record?.projectIds) ?? record?.targetProjectId ?? undefined,
    bridge_id: first(record?.bridgeIds) ?? record?.targetBridgeId ?? undefined,
    template_id: first(record?.templateIds) ?? record?.targetTemplateId ?? undefined,
    type: type || record?.type || "fact",
  };
}

export const MEMORY_TYPES = [
  { value: "fact", label: "Fact" },
  { value: "habit", label: "Habit" },
  { value: "episode", label: "Episode" },
  { value: "expertise", label: "Expertise" },
  { value: "skill", label: "Skill" },
];

export const MemoryScopeSelector: React.FC<MemoryScopeSelectorProps> = ({
  value,
  onChange,
  readOnly = false,
  disabled = false,
  hideTypeSelect = false,
  className = "",
  debugPrefix = "memory-scope",
}) => {
  const { data: identitiesData } = useListAgentIdentitiesQuery();
  const { data: projectsData } = useListSidebarProjectsQuery();
  const { data: bridgesData } = useListBridgesQuery();
  const { data: templatesData } = useListAgentTemplatesQuery();

  const agentIdentities = useMemo(() => {
    const list = Array.isArray(identitiesData?.agents)
      ? identitiesData.agents
      : Array.isArray(identitiesData)
      ? identitiesData
      : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      .map((item: any) => ({
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        id: String(item.agent_id || item.agentId || item.id || ""),
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        name: String(item.name || item.slug || item.agent_id || item.agentId || "Unnamed Agent"),
      }))
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      .filter((item: any) => Boolean(item.id));
  }, [identitiesData]);

  const projects = useMemo(() => {
    const list = Array.isArray(projectsData) ? projectsData : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      .map((item: any) => ({
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        id: String(item.projectId || item.project_id || item.id || ""),
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        name: String(item.name || item.title || item.projectId || "Unnamed Project"),
      }))
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      .filter((item: any) => Boolean(item.id));
  }, [projectsData]);

  const bridges = useMemo(() => {
    const raw = bridgesData?.bridges || bridgesData || [];
    const list = Array.isArray(raw) ? raw : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      .map((item: any) => ({
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        id: String(item.bridge_id || item.bridgeId || item.id || ""),
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        name: String(item.name || item.label || item.bridge_id || item.bridgeId || "Unnamed Bridge"),
      }))
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      .filter((item: any) => Boolean(item.id));
  }, [bridgesData]);

  const templates = useMemo(() => {
    const raw = templatesData?.templates || templatesData || [];
    const list = Array.isArray(raw) ? raw : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      .map((item: any) => ({
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        id: String(item.template_id || item.templateId || item.id || ""),
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        name: String(item.name || item.title || item.template_id || "Unnamed Template"),
      }))
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      .filter((item: any) => Boolean(item.id));
  }, [templatesData]);


  const labelFor = (items: Array<{ id: string; name: string }>, id?: string) => {
    if (!id) return "";
    return items.find((item) => item.id === id)?.name || "Selected item";
  };

  const handleAgentChange = (newAgentId: string) => {
    onChange({
      ...value,
      agent_id: newAgentId || undefined,
    });
  };

  const handleProjectChange = (newValue: string) => {
    onChange({
      ...value,
      project_id: newValue || undefined,
    });
  };

  const handleBridgeChange = (newValue: string) => {
    onChange({
      ...value,
      bridge_id: newValue || undefined,
    });
  };

  const handleTemplateChange = (newValue: string) => {
    onChange({
      ...value,
      template_id: newValue || undefined,
    });
  };

  const handleTypeChange = (newValue: string) => {
    onChange({
      ...value,
      type: newValue || undefined,
    });
  };

  const summaryParts: string[] = [];
  if (value.agent_id) {
    summaryParts.push(`agent: ${labelFor(agentIdentities, value.agent_id)}`);
  }
  if (value.project_id) summaryParts.push(`project: ${labelFor(projects, value.project_id)}`);
  if (value.bridge_id) summaryParts.push(`bridge: ${labelFor(bridges, value.bridge_id)}`);
  if (value.template_id) summaryParts.push(`template: ${labelFor(templates, value.template_id)}`);
  if (value.type) summaryParts.push(`type: ${MEMORY_TYPES.find((t) => t.value === value.type)?.label || value.type}`);

  const summaryText = summaryParts.length > 0 ? summaryParts.join(" · ") : "Global scope (no specific binding)";

  return (
    <div className={`space-y-3 ${className}`}>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {!hideTypeSelect && (
          <div>
            <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
              Memory Type
            </label>
            <Select
              data-debug-id={`${debugPrefix}-type-select`}
              id={`${debugPrefix}-type-select`}
              value={value.type || ""}
              onChange={handleTypeChange}
              disabled={disabled || readOnly}
              width="full"
            >
              <option value="">Select Type...</option>
              {MEMORY_TYPES.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </Select>
          </div>
        )}

        <div>
          <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
            Agent Identity
          </label>
          <Select
            data-debug-id={`${debugPrefix}-agent-select`}
            id={`${debugPrefix}-agent-select`}
            value={value.agent_id || ""}
            onChange={handleAgentChange}
            disabled={disabled || readOnly}
            width="full"
          >
            <option value="">Any agent</option>
            {agentIdentities.map((a) => (
              <option key={a.id} value={a.id}>
                {a.name}
              </option>
            ))}
          </Select>
        </div>


        <div>
          <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
            Project
          </label>
          <Select
            data-debug-id={`${debugPrefix}-project-select`}
            id={`${debugPrefix}-project-select`}
            value={value.project_id || ""}
            onChange={handleProjectChange}
            disabled={disabled || readOnly}
            width="full"
          >
            <option value="">Any project</option>
            {projects.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </Select>
        </div>

        <div>
          <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
            Bridge
          </label>
          <Select
            data-debug-id={`${debugPrefix}-bridge-select`}
            id={`${debugPrefix}-bridge-select`}
            value={value.bridge_id || ""}
            onChange={handleBridgeChange}
            disabled={disabled || readOnly}
            width="full"
          >
            <option value="">Any bridge</option>
            {bridges.map((b) => (
              <option key={b.id} value={b.id}>
                {b.name}
              </option>
            ))}
          </Select>
        </div>

        <div>
          <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
            Template
          </label>
          <Select
            data-debug-id={`${debugPrefix}-template-select`}
            id={`${debugPrefix}-template-select`}
            value={value.template_id || ""}
            onChange={handleTemplateChange}
            disabled={disabled || readOnly}
            width="full"
          >
            <option value="">Any template</option>
            {templates.map((tpl) => (
              <option key={tpl.id} value={tpl.id}>
                {tpl.name}
              </option>
            ))}
          </Select>
        </div>
      </div>

      <div
        data-debug-id={`${debugPrefix}-summary`}
        id={`${debugPrefix}-summary`}
        className="text-xs italic text-gray-500 dark:text-gray-400 bg-gray-50 dark:bg-gray-900/50 p-2 rounded border border-gray-200 dark:border-gray-700/50"
      >
        Scope Summary: <span className="font-medium text-gray-700 dark:text-gray-300">{summaryText}</span>
      </div>
    </div>
  );
};
