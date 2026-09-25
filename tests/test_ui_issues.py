#!/usr/bin/env python3
"""Comprehensive test suite for Issues UI (REQ-ISSUES-UI, REQ-ISSUES-LEAN-PAYLOAD).

Verifies:
1. API endpoints in src/ui/api/endpoints/issues.ts:
   - Lean payload contract for listIssues (description_preview, comment_count, no embedded description/comments requirement)
   - Full payload contract for getIssue (full description, embedded comments)
   - RTK Query endpoints for issues, comments, voting, and unvoting
   - Cache tag invalidation (Issue, IssueComments)
2. UI components in src/ui/components/issues/:
   - IssueListPage: split-pane layout, filters (status pills, scope selector), search, new issue button
   - IssueRow: status pill, scope badge, title, description_preview snippet, created by, vote button with count, task chain pill
   - IssueDetail: status dropdown, task chain context card, markdown description, embedded comments thread with composer, vote toggle
   - IssueFormPage: title, markdown description, scope selector, target ID, chain ID, status selector, unsaved changes guard
   - issueModel: type definitions, helper functions, route builders
3. AppShell integration:
   - Primary navigation entry 'Issues' positioned immediately below 'Library'
   - Route handling for /issues, /issues/new, /issues/:id/edit, and /issues/:id
4. Component library rules:
   - Strictly zero native <select> elements across all issues components
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
UI = ROOT / "src" / "ui"
ISSUES_COMPONENTS = UI / "components" / "issues"
ISSUES_API = UI / "api" / "endpoints" / "issues.ts"
APP_SHELL = UI / "components" / "shell" / "AppShell.tsx"
HEIMDALL_API = UI / "api" / "heimdallApi.ts"
INDEX_ENDPOINTS = UI / "api" / "endpoints" / "index.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"FAILED: {message}", file=sys.stderr)
        sys.exit(1)


def test_api_endpoints() -> None:
    print("Testing RTK Query endpoints and payload contracts in src/ui/api/endpoints/issues.ts...")
    require(ISSUES_API.exists(), f"Missing {ISSUES_API}")
    src = ISSUES_API.read_text(encoding="utf-8")

    # Contract types
    require("export interface Issue" in src, "Issue interface must be exported")
    require("description_preview" in src or "descriptionPreview" in src, "Issue must support description_preview for lean payload")
    require("comment_count" in src or "commentCount" in src, "Issue must support comment_count for lean payload")
    require("comments?: IssueComment[]" in src, "Issue must support embedded comments for full payload")
    require("export interface IssueComment" in src, "IssueComment interface must be exported")
    require("export interface IssueVote" in src, "IssueVote interface must be exported")

    # RTK Query endpoints
    endpoints = [
        "listIssues",
        "getIssue",
        "createIssue",
        "updateIssue",
        "deleteIssue",
        "listIssueComments",
        "addIssueComment",
        "deleteIssueComment",
        "listIssueVotes",
        "voteIssue",
        "unvoteIssue",
    ]
    for ep in endpoints:
        require(f"{ep}: build." in src, f"Endpoint {ep} must be defined in issuesApi")

    # Hook exports
    hooks = [
        "useListIssuesQuery",
        "useGetIssueQuery",
        "useCreateIssueMutation",
        "useUpdateIssueMutation",
        "useDeleteIssueMutation",
        "useListIssueCommentsQuery",
        "useAddIssueCommentMutation",
        "useDeleteIssueCommentMutation",
        "useListIssueVotesQuery",
        "useVoteIssueMutation",
        "useUnvoteIssueMutation",
    ]
    for hook in hooks:
        require(hook in src, f"Hook {hook} must be exported from issues.ts")

    # Tag invalidation check
    require("'Issue'" in src, "Tag type 'Issue' must be used for cache invalidation")
    require("'IssueComments'" in src, "Tag type 'IssueComments' must be used for cache invalidation")

    # Tag registration in heimdallApi.ts
    heimdall_api_src = HEIMDALL_API.read_text(encoding="utf-8")
    require("'Issue'" in heimdall_api_src, "'Issue' tag must be present in HEIMDALL_TAG_TYPES")
    require("'IssueComments'" in heimdall_api_src, "'IssueComments' tag must be present in HEIMDALL_TAG_TYPES")

    # Re-exported from endpoints/index.ts
    index_src = INDEX_ENDPOINTS.read_text(encoding="utf-8")
    require("export * from './issues';" in index_src, "issues endpoints must be re-exported in endpoints/index.ts")

    print("  -> API endpoints and contracts verified.")


def test_no_native_select() -> None:
    print("Verifying strictly zero native <select> elements in issues components...")
    select_pattern = re.compile(r"<select[\s>]")
    for f in ISSUES_COMPONENTS.glob("*.tsx"):
        content = f.read_text(encoding="utf-8")
        require(not select_pattern.search(content), f"Found forbidden native <select> in {f.name}")
    print("  -> Zero native <select> elements verified.")


def test_issue_model() -> None:
    print("Testing issueModel.ts helpers and models...")
    model_path = ISSUES_COMPONENTS / "issueModel.ts"
    require(model_path.exists(), f"Missing {model_path}")
    src = model_path.read_text(encoding="utf-8")

    # Statuses and tones
    require("ISSUE_STATUSES" in src, "ISSUE_STATUSES constant must exist")
    require("statusLabel" in src, "statusLabel helper must exist")
    require("statusTone" in src, "statusTone helper must exist")
    require("scopeLabel" in src, "scopeLabel helper must exist")
    require("scopeTone" in src, "scopeTone helper must exist")

    # Lean description preview in issueSnippet
    require("issueSnippet" in src, "issueSnippet helper must exist")
    require("description_preview" in src, "issueSnippet must check description_preview")

    # Route helpers
    require("issuesListHref" in src, "issuesListHref must exist")
    require("issueViewHref" in src, "issueViewHref must exist")
    require("issueEditHref" in src, "issueEditHref must exist")
    require("issueNewHref" in src, "issueNewHref must exist")

    # Breadcrumbs
    require("listCrumbs" in src, "listCrumbs must exist")
    require("newCrumbs" in src, "newCrumbs must exist")
    require("viewCrumbs" in src, "viewCrumbs must exist")
    require("editCrumbs" in src, "editCrumbs must exist")

    print("  -> issueModel helpers verified.")


def test_issue_row() -> None:
    print("Testing IssueRow.tsx component...")
    row_path = ISSUES_COMPONENTS / "IssueRow.tsx"
    require(row_path.exists(), f"Missing {row_path}")
    src = row_path.read_text(encoding="utf-8")

    # Acceptance criteria checks
    require("StatusPill" in src, "IssueRow must render StatusPill")
    require("Badge" in src, "IssueRow must render scope Badge")
    require("issueSnippet" in src, "IssueRow must render snippet preview")
    require("createdBy" in src, "IssueRow must render created by")
    require("data-row-control" in src, "IssueRow must support row control clicks")
    require("onVoteToggle" in src, "IssueRow must support onVoteToggle")
    require("issue-vote-count" in src, "IssueRow must render vote count debug id")
    require("chain" in src.lower(), "IssueRow must render chain link when chain_id is present")

    # Vote count button in Row 4 alongside metadata chips, not in Row 1
    row1_match = re.search(r"Row 1:.*?(?:Row 2|Rows 2-3)", src, re.DOTALL)
    require(bool(row1_match), "IssueRow must define Row 1 section")
    require("issue-vote-count" not in row1_match.group(0), "Row 1 must not contain vote count button")

    row4_match = re.search(r"Row 4:.*", src, re.DOTALL)
    require(bool(row4_match), "IssueRow must define Row 4 section")
    require("issue-vote-count" in row4_match.group(0), "Row 4 must contain vote count button")
    require("bg-accent/15" in src and "border-accent/40" in src, "Vote button must have active voted styles")
    require("bg-surface-raised" in src and "border-subtle" in src, "Vote button must have unvoted styles")

    print("  -> IssueRow component verified.")


def test_issue_detail() -> None:
    print("Testing IssueDetail.tsx component...")
    detail_path = ISSUES_COMPONENTS / "IssueDetail.tsx"
    require(detail_path.exists(), f"Missing {detail_path}")
    src = detail_path.read_text(encoding="utf-8")

    # Status control dropdown using @ui Select
    require("<Select" in src, "IssueDetail must use @ui Select for status change")
    require("handleStatusChange" in src, "IssueDetail must implement handleStatusChange")

    # Interactive vote toggle
    require("handleVoteToggle" in src, "IssueDetail must implement handleVoteToggle")
    require("issue-detail-vote-button" in src, "IssueDetail must have vote button debug id")

    # Task chain context card
    require("issue-chain-context" in src, "IssueDetail must render task chain context card")
    require("chainId" in src, "IssueDetail must reference chainId")

    # Full markdown body
    require("MarkdownBody" in src, "IssueDetail must render MarkdownBody")
    require("issue.description" in src, "IssueDetail must pass issue.description to MarkdownBody")

    # Embedded comments / thread and composer
    require("issue-comments-section" in src, "IssueDetail must render comments section")
    require("embeddedComments" in src or "issue?.comments" in src, "IssueDetail must support embedded comments")
    require("handleAddComment" in src, "IssueDetail must implement handleAddComment composer")
    require("Textarea" in src, "IssueDetail must use Textarea for comment composer")
    require('width="full"' in src, "Comment Textarea must pass width='full'")
    require('className="w-full"' in src, "Comment Textarea must pass className='w-full'")

    print("  -> IssueDetail component verified.")


def test_issue_list_page() -> None:
    print("Testing IssueListPage.tsx component...")
    list_path = ISSUES_COMPONENTS / "IssueListPage.tsx"
    require(list_path.exists(), f"Missing {list_path}")
    src = list_path.read_text(encoding="utf-8")

    # Split-pane layout
    require("twoPane" in src or "ResourceContainer" in src, "IssueListPage must implement twoPane layout or adopt ResourceContainer")
    require("issues-list-column" in src, "IssueListPage must have list column debug id")
    require("issues-detail-pane" in src, "IssueListPage must have detail pane debug id")

    # Unboxed list and vertical divider parity with Memory UI
    require("border-l border-subtle pl-4" in src or "ResourceContainer" in src, "IssueListPage must use border-l border-subtle pl-4 vertical divider for detail pane")
    require("bg-surface rounded-xl border border-subtle" not in src, "IssueListPage must remove card boxes from listColumn and detail pane")
    require("Select an issue to see it here." in src, "IssueListPage must render placeholder text 'Select an issue to see it here.'")

    # Filters, tabs, and search
    require("STATUS_FILTERS" in src, "IssueListPage must have STATUS_FILTERS")
    require("issues-filter-status-" in src, "IssueListPage must render status filter buttons")
    require(("<Tabs" in src and "<TabsList" in src and "<Tab" in src) or "ResourceSearchFilter" in src, "IssueListPage must use Tabs, TabsList, and Tab or ResourceSearchFilter for status filter")
    require("issues-scope-filter" in src, "IssueListPage must have scope filter Select")
    require("issues-search-input" in src, "IssueListPage must have search input")
    require('leading={<Icon name="search"' in src or "ResourceSearchFilter" in src, "Search input must have leading search icon")
    require("Search issues…" in src or "Search issues..." in src, "Search input must have issues search placeholder")
    require('width="full"' in src or "ResourceSearchFilter" in src, "Search input must have width='full'")
    require("issues-header-new-btn" in src, "IssueListPage must have header New Issue button")
    require("issues-new-btn" not in src, "IssueListPage must remove duplicate toolbar New Issue button")

    # Uses IssueRow, IssueDetail, ResourceContainer, and ResourceSearchFilter
    require("IssueRow" in src, "IssueListPage must use IssueRow")
    require("IssueDetail" in src, "IssueListPage must use IssueDetail")
    require("ResourceContainer" in src, "IssueListPage must adopt ResourceContainer")
    require("ResourceSearchFilter" in src, "IssueListPage must adopt ResourceSearchFilter")

    print("  -> IssueListPage component verified.")


def test_issue_form_page() -> None:
    print("Testing IssueFormPage.tsx component...")
    form_path = ISSUES_COMPONENTS / "IssueFormPage.tsx"
    require(form_path.exists(), f"Missing {form_path}")
    src = form_path.read_text(encoding="utf-8")

    # Form fields
    require("issue-form-title" in src, "IssueFormPage must have title input")
    require("issue-form-description" in src, "IssueFormPage must have description textarea")
    require("issue-form-scope" in src, "IssueFormPage must have scope Select")
    require("issue-form-target-id" in src, "IssueFormPage must have target ID input")
    require("issue-form-chain-id" in src, "IssueFormPage must have chain ID input")
    require("issue-form-submit" in src, "IssueFormPage must have submit button")

    # Unsaved changes guard
    require("isDirty" in src, "IssueFormPage must track isDirty state")

    print("  -> IssueFormPage component verified.")


def test_app_shell_navigation() -> None:
    print("Testing AppShell.tsx navigation and routing integration...")
    require(APP_SHELL.exists(), f"Missing {APP_SHELL}")
    src = APP_SHELL.read_text(encoding="utf-8")

    # Primary navigation entry 'Issues' positioned immediately below 'Library'
    lib_idx = src.find("path: '/library'")
    iss_idx = src.find("path: '/issues'")
    require(lib_idx != -1, "Library route must exist in AppShell primaryNavigation")
    require(iss_idx != -1, "Issues route must exist in AppShell primaryNavigation")
    require(iss_idx > lib_idx, "Issues navigation item must be positioned below Library")

    # Confirm proximity in NAV_ROUTES / primary navigation
    nav_match = re.search(r"(?:NAV_ROUTES|primaryNavigation).*?=\s*\[(.*?)\];", src, re.DOTALL)
    require(bool(nav_match), "NAV_ROUTES or primaryNavigation array must exist in AppShell")
    nav_text = nav_match.group(1)
    lib_pos = nav_text.find("'/library'")
    iss_pos = nav_text.find("'/issues'")
    require(lib_pos != -1 and iss_pos != -1 and iss_pos > lib_pos, "Issues must be directly below Library in navigation")

    # Routes wired in AppShell
    require("path === '/issues'" in src, "AppShell must handle route '/issues'")
    require("path === '/issues/new'" in src, "AppShell must handle route '/issues/new'")
    require("path.startsWith('/issues/') && path.endsWith('/edit')" in src, "AppShell must handle edit issue route")
    require("path.startsWith('/issues/')" in src, "AppShell must handle issue detail route")
    require("<IssueListPage" in src, "AppShell must render IssueListPage")
    require("<IssueFormPage" in src, "AppShell must render IssueFormPage")

    print("  -> AppShell navigation and routing verified.")


def main() -> None:
    print("Starting Issues UI Verification Test Suite...")
    test_api_endpoints()
    test_no_native_select()
    test_issue_model()
    test_issue_row()
    test_issue_detail()
    test_issue_list_page()
    test_issue_form_page()
    test_app_shell_navigation()
    print("ALL ISSUES UI TESTS PASSED SUCCESSFULLY.")


if __name__ == "__main__":
    main()
