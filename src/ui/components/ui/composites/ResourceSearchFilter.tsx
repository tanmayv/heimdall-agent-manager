/**
 * ResourceSearchFilter — unified search input, status tabs, select filters, and item counter.
 * ------------------------------------------------------------------
 * Purpose: Provides a standardized filter toolbar and item counter for resource list pages
 * based on the look and feel of IssueListPage.tsx.
 */
import React from 'react';
import { Input } from '../primitives/Input';
import { Select, type SelectOption } from '../primitives/Select';
import { Icon } from '../primitives/Icon';
import { Tabs, TabsList, Tab } from './Tabs';
import type { RootClassNameProps } from '../types';

export interface ResourceFilterSelectOption {
  value: string;
  label: React.ReactNode;
}

export interface ResourceFilterSelect {
  value: string;
  onChange: (value: string) => void;
  options: (SelectOption | ResourceFilterSelectOption)[];
  ariaLabel?: string;
  placeholder?: string;
  widthClassName?: string;
  debugId?: string;
  disabled?: boolean;
}

export interface ResourceTabOption {
  value: string;
  label: React.ReactNode;
  debugId?: string;
  disabled?: boolean;
}

export interface ResourceCounterProps extends RootClassNameProps {
  /** Number of items. */
  count: number;
  /** Singular label. Defaults to "item". */
  label?: string;
  /** Plural label. Defaults to `${label}s`. */
  labelPlural?: string;
  /** Data debug ID. */
  dataDebugId?: string;
}

export function ResourceCounter({
  count,
  label = 'item',
  labelPlural,
  dataDebugId,
  className,
}: ResourceCounterProps) {
  const plural = labelPlural || `${label}s`;
  return (
    <div
      data-debug-id={dataDebugId}
      className={[
        'p-2 border-t border-subtle text-[11px] text-muted text-right px-3 shrink-0',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      {count} {count === 1 ? label : plural}
    </div>
  );
}

export interface ResourceSearchFilterProps extends RootClassNameProps {
  /** Search query value. */
  searchQuery?: string;
  /** Callback fired when search query changes. */
  onSearchChange?: (query: string) => void;
  /** Placeholder for the search input. Defaults to "Search…". */
  searchPlaceholder?: string;
  /** Data debug ID for the search input. */
  searchDebugId?: string;
  /** Ref forwarded to the search input. */
  searchRef?: React.Ref<HTMLInputElement>;

  /** Optional custom data debug ID for the search clear button. */
  searchClearDebugId?: string;

  /** Active tab value. */
  activeTab?: string;
  /** Callback fired when tab selection changes. */
  onTabChange?: (tab: string) => void;
  /** Tab options to render in the status tabs list. */
  tabs?: ResourceTabOption[];
  /** Accessibility label for the tabs list. Defaults to "Filter tabs". */
  tabsLabel?: string;

  /** Select dropdown filters rendered in the filter row. */
  filters?: ResourceFilterSelect[];

  /** Extra custom filter controls or action elements to place in the filter row. */
  children?: React.ReactNode;

  /** Total item count. When provided with showFooterCounter=true, renders a footer counter. */
  itemsCount?: number;
  /** Singular item label for the count. Defaults to "item". */
  itemsLabel?: string;
  /** Plural item label for the count. Defaults to `${itemsLabel}s`. */
  itemsLabelPlural?: string;
  /** Whether to render the footer counter bar. */
  showFooterCounter?: boolean;
  /** Data debug ID for the footer counter. */
  counterDebugId?: string;
}

export function ResourceSearchFilter({
  searchQuery,
  onSearchChange,
  searchPlaceholder = 'Search…',
  searchDebugId,
  searchRef,
  searchClearDebugId,
  activeTab,
  onTabChange,
  tabs,
  tabsLabel = 'Filter tabs',
  filters,
  children,
  itemsCount,
  itemsLabel = 'item',
  itemsLabelPlural,
  showFooterCounter = false,
  counterDebugId,
  className,
}: ResourceSearchFilterProps) {
  const hasTabs = Boolean(tabs && tabs.length > 0 && onTabChange);
  const hasFilters = Boolean((filters && filters.length > 0) || children);

  return (
    <div className={['flex flex-col shrink-0', className].filter(Boolean).join(' ')}>
      {/* Search Bar */}
      {onSearchChange !== undefined ? (
        <div className="p-2 border-b border-subtle flex items-center gap-2 shrink-0">
          <Input
            ref={searchRef}
            value={searchQuery ?? ''}
            onChange={onSearchChange}
            width="full"
            leading={<Icon name="search" size="sm" />}
            trailing={
              searchQuery ? (
                <button
                  type="button"
                  onClick={() => onSearchChange('')}
                  className="text-muted hover:text-primary p-0.5 rounded focus-visible:outline-none transition-colors"
                  aria-label="Clear search"
                  data-debug-id={searchClearDebugId ?? "resource-search-clear-btn"}
                >
                  <Icon name="close" size="sm" />
                </button>
              ) : undefined
            }
            placeholder={searchPlaceholder}
            size="sm"
            data-debug-id={searchDebugId}
          />
        </div>
      ) : null}

      {/* Filter Row: Tabs & Select dropdowns */}
      {hasTabs || hasFilters ? (
        <div className="flex items-center justify-between border-b border-subtle shrink-0 min-w-0">
          {hasTabs ? (
            <Tabs value={activeTab ?? ''} onChange={onTabChange!}>
              <TabsList label={tabsLabel} className="border-b-0">
                {tabs!.map((tab) => (
                  <Tab
                    key={tab.value}
                    value={tab.value}
                    disabled={tab.disabled}
                    data-debug-id={tab.debugId}
                  >
                    {tab.label}
                  </Tab>
                ))}
              </TabsList>
            </Tabs>
          ) : (
            <div />
          )}

          {hasFilters ? (
            <div className="flex items-center gap-2 shrink-0 py-1 pr-2">
              {filters?.map((f, idx) => (
                <div key={idx} className={f.widthClassName || 'w-32'}>
                  <Select
                    value={f.value}
                    onChange={f.onChange}
                    size="sm"
                    disabled={f.disabled}
                    aria-label={f.ariaLabel || 'Filter'}
                    data-debug-id={f.debugId}
                    options={f.options as SelectOption[]}
                  />
                </div>
              ))}
              {children}
            </div>
          ) : null}
        </div>
      ) : null}

      {/* Optional footer counter */}
      {showFooterCounter && itemsCount !== undefined ? (
        <ResourceCounter
          count={itemsCount}
          label={itemsLabel}
          labelPlural={itemsLabelPlural}
          dataDebugId={counterDebugId}
        />
      ) : null}
    </div>
  );
}

export default ResourceSearchFilter;
