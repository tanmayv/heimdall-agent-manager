import React, { useMemo } from "react";
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
      .map((item: any) => ({
        id: String(item.agent_id || item.agentId || item.id || ""),
        name: String(item.name || item.slug || item.agent_id || item.agentId || "Unnamed Agent"),
      }))
      .filter((item: any) => Boolean(item.id));
  }, [identitiesData]);

  const projects = useMemo(() => {
    const list = Array.isArray(projectsData) ? projectsData : [];
    return list
      .map((item: any) => ({
        id: String(item.projectId || item.project_id || item.id || ""),
        name: String(item.name || item.title || item.projectId || "Unnamed Project"),
      }))
      .filter((item: any) => Boolean(item.id));
  }, [projectsData]);

  const bridges = useMemo(() => {
    const raw = bridgesData?.bridges || bridgesData || [];
    const list = Array.isArray(raw) ? raw : [];
    return list
      .map((item: any) => ({
        id: String(item.bridge_id || item.bridgeId || item.id || ""),
        name: String(item.name || item.label || item.bridge_id || item.bridgeId || "Unnamed Bridge"),
      }))
      .filter((item: any) => Boolean(item.id));
  }, [bridgesData]);

  const templates = useMemo(() => {
    const raw = templatesData?.templates || templatesData || [];
    const list = Array.isArray(raw) ? raw : [];
    return list
      .map((item: any) => ({
        id: String(item.template_id || item.templateId || item.id || ""),
        name: String(item.name || item.title || item.template_id || "Unnamed Template"),
      }))
      .filter((item: any) => Boolean(item.id));
  }, [templatesData]);


  const labelFor = (items: Array<{ id: string; name: string }>, id?: string) => {
    if (!id) return "";
    return items.find((item) => item.id === id)?.name || "Selected item";
  };

  const handleAgentChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    const newAgentId = e.target.value;
    onChange({
      ...value,
      agent_id: newAgentId || undefined,
    });
  };

  const handleProjectChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    onChange({
      ...value,
      project_id: e.target.value || undefined,
    });
  };

  const handleBridgeChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    onChange({
      ...value,
      bridge_id: e.target.value || undefined,
    });
  };

  const handleTemplateChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    onChange({
      ...value,
      template_id: e.target.value || undefined,
    });
  };

  const handleTypeChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    onChange({
      ...value,
      type: e.target.value || undefined,
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
            <select
              data-debug-id={`${debugPrefix}-type-select`}
              id={`${debugPrefix}-type-select`}
              value={value.type || ""}
              onChange={handleTypeChange}
              disabled={disabled || readOnly}
              className="w-full text-sm rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 p-2 focus:ring-blue-500 focus:border-blue-500"
            >
              <option value="">Select Type...</option>
              {MEMORY_TYPES.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </select>
          </div>
        )}

        <div>
          <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
            Agent Identity
          </label>
          <select
            data-debug-id={`${debugPrefix}-agent-select`}
            id={`${debugPrefix}-agent-select`}
            value={value.agent_id || ""}
            onChange={handleAgentChange}
            disabled={disabled || readOnly}
            className="w-full text-sm rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 p-2 focus:ring-blue-500 focus:border-blue-500"
          >
            <option value="">Any agent</option>
            {agentIdentities.map((a) => (
              <option key={a.id} value={a.id}>
                {a.name}
              </option>
            ))}
          </select>
        </div>


        <div>
          <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
            Project
          </label>
          <select
            data-debug-id={`${debugPrefix}-project-select`}
            id={`${debugPrefix}-project-select`}
            value={value.project_id || ""}
            onChange={handleProjectChange}
            disabled={disabled || readOnly}
            className="w-full text-sm rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 p-2 focus:ring-blue-500 focus:border-blue-500"
          >
            <option value="">Any project</option>
            {projects.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
            Bridge
          </label>
          <select
            data-debug-id={`${debugPrefix}-bridge-select`}
            id={`${debugPrefix}-bridge-select`}
            value={value.bridge_id || ""}
            onChange={handleBridgeChange}
            disabled={disabled || readOnly}
            className="w-full text-sm rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 p-2 focus:ring-blue-500 focus:border-blue-500"
          >
            <option value="">Any bridge</option>
            {bridges.map((b) => (
              <option key={b.id} value={b.id}>
                {b.name}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
            Template
          </label>
          <select
            data-debug-id={`${debugPrefix}-template-select`}
            id={`${debugPrefix}-template-select`}
            value={value.template_id || ""}
            onChange={handleTemplateChange}
            disabled={disabled || readOnly}
            className="w-full text-sm rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 p-2 focus:ring-blue-500 focus:border-blue-500"
          >
            <option value="">Any template</option>
            {templates.map((tpl) => (
              <option key={tpl.id} value={tpl.id}>
                {tpl.name}
              </option>
            ))}
          </select>
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
