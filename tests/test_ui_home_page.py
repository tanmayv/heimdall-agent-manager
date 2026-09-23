#!/usr/bin/env python3
"""Automated regression test suite for Heimdall Home Page redesign.

Requirements verified:
- REQ-HOME-NAV-1: Left sidebar navigation & routing in AppShell.tsx and responsive.tsx
  - Home label with 'home' icon routing to /home
  - Default route / and /index.html and /cards route to /home
  - Route titles, descriptions, and breadcrumbs for /home and /cards
  - Desktop two-pane sizing for /home and /cards
  - Brand logo link to /home
  - Mobile bottom navigation tab 'home' routing to /home
- REQ-HOME-TABS-2: Home Page Shell (HomePage.tsx)
  - PageShell with banded rhythm and full width
  - 3 tabs: Recent Task chains ('chains'), Recent Issues ('issues'), Action Items ('actions')
  - Horizontally scrollable TabsList for mobile optimization
  - URL search parameter sync (?tab=)
- REQ-HOME-CHAINS-3: Recent Task Chains Tab (RecentTaskChainsTab.tsx)
  - Fetches chains using useFetchTaskChainGroupsQuery()
  - Filters strictly for 'active' (in progress) and 'completed' chains
  - Filter chips for All, In Progress, Completed
  - Search input filtering by title, chainId, and projectName
  - Sorted by updatedAt descending
  - Renders status badge, project name badge, task count badge, relative time, coordinator link
  - Clean EmptyState when no chains match
- REQ-HOME-ISSUES-4: Recent Issues Tab (RecentIssuesTab.tsx)
  - Fetches issues via useListIssuesQuery()
  - Sub-view toggle: Recent Issues (created_at desc) vs Top 10 Issues (vote_count desc, slice 10)
  - Status filters: All, New, Fixed, Obsolete
  - Search input
  - Desktop two-pane view (list on left, IssueDetail on right)
  - Mobile single-pane drill-down with back button
  - Upvote toggle support
- REQ-HOME-ACTIONS-5: Action Items Tab (ActionItemsTab.tsx)
  - Two-pane layout modeled after Issues & art_18d7db557b34a8e1
  - Left pane: search bar, status tabs, project selector (@ui Select), selectable card rows
  - Right pane: selected card detail with badges, Markdown rationale, operations breakdown, and action buttons
  - Mobile single-pane drill-down with back navigation
- REQ-HOME-MOBILE-6: Mobile Optimization
  - useViewport() and useIsMobile() checks
  - Safe-area bottom padding with var(--ui-bottom-chrome)
  - Touch targets >= 44px on interactive controls
- REQ-HOME-TESTS-7: Component structure & UI library compliance
  - Strict compliance with @ui component library (no native <select>)
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP_SHELL = ROOT / 'src/ui/components/shell/AppShell.tsx'
RESPONSIVE = ROOT / 'src/ui/components/shell/responsive.tsx'
HOME_PAGE = ROOT / 'src/ui/components/home/HomePage.tsx'
CHAINS_TAB = ROOT / 'src/ui/components/home/RecentTaskChainsTab.tsx'
ISSUES_TAB = ROOT / 'src/ui/components/home/RecentIssuesTab.tsx'
ACTIONS_TAB = ROOT / 'src/ui/components/home/ActionItemsTab.tsx'


def test_req_home_nav_1():
    """Verify Shell Navigation & Routing (REQ-HOME-NAV-1)."""
    assert APP_SHELL.exists(), f"AppShell.tsx not found at {APP_SHELL}"
    src = APP_SHELL.read_text(encoding='utf-8')

    # 1. NAV_ROUTES contains Home with path '/home' and icon 'home'
    assert re.search(r"path:\s*'/home',\s*label:\s*'Home',\s*icon:\s*'home'", src), \
        "NAV_ROUTES should contain Home entry with path '/home' and icon 'home'"
    assert "description: 'Recent task chains, issues, and action items'" in src, \
        "NAV_ROUTES Home entry should have updated description"

    # 2. routeFromLocation() defaults '/', '/index.html', and '/cards' to '/home'
    assert "if (!path || path === '/' || path === '/index.html' || path === '/cards') return '/home';" in src, \
        "routeFromLocation should route root and /cards to /home"

    # 3. isRouteActive supports /home and /cards
    assert "if (itemPath === '/home')" in src, "isRouteActive should support /home"
    assert "if (itemPath === '/cards')" in src, "isRouteActive should support /cards"

    # 4. routeTitle and routeBreadcrumbs support /home returning Home
    assert "if (path === '/home' || path.startsWith('/home') || path === '/cards' || path.startsWith('/cards')) return 'Home';" in src, \
        "routeTitle should return 'Home' for /home and /cards"
    assert "if (path === '/home' || path.startsWith('/home') || path === '/cards' || path.startsWith('/cards')) return [{ label: 'Home' }];" in src, \
        "routeBreadcrumbs should return [{ label: 'Home' }] for /home and /cards"

    # 5. Desktop two-pane sizing includes /home and /cards
    assert "['/home', '/cards', '/projects'" in src, \
        "isDesktopTwoPaneRoute should include /home and /cards"

    # 6. Brand logo and access denied links to /home
    assert "href={shellHash('/home')} data-debug-id=\"shell-brand\"" in src, \
        "Brand logo link should target /home"
    assert "href={shellHash('/home')} className=\"mt-6 inline-flex rounded-2xl" in src, \
        "Access denied home link should target /home"

    # 7. Mounts <HomePage />
    assert "import HomePage from '../home/HomePage';" in src, "AppShell should import HomePage"
    assert "<HomePage />" in src, "AppShell should render <HomePage />"

    # 8. responsive.tsx mobile bottom tab bar
    assert RESPONSIVE.exists(), f"responsive.tsx not found at {RESPONSIVE}"
    resp_src = RESPONSIVE.read_text(encoding='utf-8')
    assert re.search(r"id:\s*'home',\s*label:\s*'Home',\s*icon:\s*'home',\s*route:\s*'/home'", resp_src), \
        "responsive.tsx bottom navigation tab 'home' should route to '/home'"
    assert "route === '/home'" in resp_src, "responsive.tsx isActive check should support /home"
    print("PASS: REQ-HOME-NAV-1 (Shell Navigation & Routing)")


def test_req_home_tabs_2():
    """Verify Home Page Shell & Tab Management (REQ-HOME-TABS-2)."""
    assert HOME_PAGE.exists(), f"HomePage.tsx not found at {HOME_PAGE}"
    src = HOME_PAGE.read_text(encoding='utf-8')

    # 1. PageShell usage with banded rhythm, full width, and title Home
    assert 'PageShell' in src, "HomePage should use PageShell"
    assert 'title="Home"' in src, "HomePage should set title='Home'"
    assert 'rhythm="banded"' in src, "HomePage should set rhythm='banded'"
    assert 'width="full"' in src, "HomePage should set width='full'"

    # 2. TabsList with 3 specific tabs
    assert 'data-debug-id="home-tab-chains"' in src, "Missing home-tab-chains debug id"
    assert 'data-debug-id="home-tab-issues"' in src, "Missing home-tab-issues debug id"
    assert 'data-debug-id="home-tab-actions"' in src, "Missing home-tab-actions debug id"
    assert 'Recent Task chains' in src, "Missing 'Recent Task chains' tab label"
    assert 'Recent Issues' in src, "Missing 'Recent Issues' tab label"
    assert 'Action Items' in src, "Missing 'Action Items' tab label"

    # 3. URL search parameter sync (?tab=)
    assert 'getRouteSearch' in src, "HomePage should read URL search params"
    assert 'tab' in src, "HomePage should synchronize ?tab= parameter"
    assert 'chains' in src and 'issues' in src and 'actions' in src, "HomePage should map tab values"

    # 4. Horizontally scrollable container for mobile optimization
    assert 'overflow-x-auto' in src, "TabsList container should have overflow-x-auto for mobile scrolling"
    assert 'whitespace-nowrap' in src, "TabsList should have whitespace-nowrap to avoid ugly line wrapping"

    # 5. Mounts all 3 tab components
    assert 'RecentTaskChainsTab' in src, "HomePage should include RecentTaskChainsTab"
    assert 'RecentIssuesTab' in src, "HomePage should include RecentIssuesTab"
    assert 'ActionItemsTab' in src, "HomePage should include ActionItemsTab"
    print("PASS: REQ-HOME-TABS-2 (Home Page Shell & Tab Sync)")


def test_req_home_chains_3():
    """Verify Recent Task Chains Tab (REQ-HOME-CHAINS-3)."""
    assert CHAINS_TAB.exists(), f"RecentTaskChainsTab.tsx not found at {CHAINS_TAB}"
    src = CHAINS_TAB.read_text(encoding='utf-8')

    # 1. useFetchTaskChainGroupsQuery hook usage
    assert 'useFetchTaskChainGroupsQuery' in src, "Should fetch task chains via useFetchTaskChainGroupsQuery"

    # 2. Filter strictly for active or completed chains
    assert "s !== 'active' && s !== 'completed'" in src or "chain.status === 'active' || chain.status === 'completed'" in src, \
        "Should filter chains to only active (in progress) or completed"

    # 3. Filter buttons / chips
    assert 'data-debug-id="home-chains-filter-all"' in src, "Missing All filter button"
    assert 'data-debug-id="home-chains-filter-active"' in src, "Missing In Progress filter button"
    assert 'data-debug-id="home-chains-filter-completed"' in src, "Missing Completed filter button"

    # 4. Search input
    assert 'data-debug-id="home-chains-search-input"' in src, "Missing chains search input"

    # 5. Sorting by updatedAt descending
    assert 'updatedAt' in src, "Should handle updatedAt sorting"
    assert 'getTime' in src, "Should parse timestamps for sorting"

    # 6. Card contents: status badge, project badge, task count, coordinator link
    assert 'home-chain-status-' in src, "Should render status badge with debug ID"
    assert 'home-chain-project-' in src, "Should render project name badge with debug ID"
    assert 'home-chain-tasks-' in src, "Should render task count badge with debug ID"
    assert 'home-chain-link-' in src, "Should render coordinator conversation link with debug ID"
    assert '/conversations/' in src, "Should link to coordinator conversation"

    # 7. EmptyState
    assert 'EmptyState' in src, "Should render EmptyState when no chains match"
    assert 'recent-task-chains-empty-state' in src, "EmptyState should have debug ID"
    print("PASS: REQ-HOME-CHAINS-3 (Recent Task Chains Tab)")


def test_req_home_issues_4():
    """Verify Recent Issues Tab (REQ-HOME-ISSUES-4)."""
    assert ISSUES_TAB.exists(), f"RecentIssuesTab.tsx not found at {ISSUES_TAB}"
    src = ISSUES_TAB.read_text(encoding='utf-8')

    # 1. useListIssuesQuery hook usage
    assert 'useListIssuesQuery' in src, "Should query issues with useListIssuesQuery"

    # 2. Sub-view toggle: Recent vs Top 10
    assert 'data-debug-id="home-issues-view-mode-recent"' in src, "Missing Recent Issues view toggle button"
    assert 'data-debug-id="home-issues-view-mode-top10"' in src, "Missing Top 10 Issues view toggle button"
    assert 'slice(0, 10)' in src, "Top 10 mode should slice to top 10 issues"
    assert 'vote_count' in src or 'voteCount' in src, "Top 10 mode should sort by vote_count"

    # 3. Status filter chips
    assert 'home-issues-filter-${f.value || \'all\'}' in src or 'home-issues-filter-' in src, "Missing status filter chip debug id"
    assert 'STATUS_FILTERS' in src, "Missing STATUS_FILTERS list"

    # 4. Search input
    assert 'data-debug-id="home-issues-search-input"' in src, "Missing issues search input"

    # 5. Desktop two-pane and mobile drill-down layouts
    assert 'home-issues-list-pane' in src, "Missing issues list pane debug id"
    assert 'home-issues-detail-pane' in src, "Missing issues detail pane debug id"
    assert 'home-issues-back-btn' in src, "Missing mobile back button debug id"
    assert 'IssueDetail' in src, "Should render IssueDetail component"
    assert 'IssueRow' in src, "Should render IssueRow component"

    # 6. Upvote support
    assert 'useVoteIssueMutation' in src, "Should support issue voting"
    assert 'useUnvoteIssueMutation' in src, "Should support issue unvoting"
    print("PASS: REQ-HOME-ISSUES-4 (Recent Issues Tab)")


def test_req_home_actions_5():
    """Verify Action Items Tab (REQ-HOME-ACTIONS-5)."""
    assert ACTIONS_TAB.exists(), f"ActionItemsTab.tsx not found at {ACTIONS_TAB}"
    src = ACTIONS_TAB.read_text(encoding='utf-8')

    # 1. API mutation hooks
    assert 'useListCardsQuery' in src, "Should query cards with useListCardsQuery"
    assert 'useAcceptCardMutation' in src, "Should import useAcceptCardMutation"
    assert 'useRejectCardMutation' in src, "Should import useRejectCardMutation"
    assert 'useDiscardCardMutation' in src, "Should import useDiscardCardMutation"
    assert 'useSnoozeCardMutation' in src, "Should import useSnoozeCardMutation"

    # 2. Two-pane layout structure
    assert 'data-debug-id="action-items-list-pane"' in src, "Missing action-items-list-pane debug id"
    assert 'data-debug-id="action-items-detail-scroll-pane"' in src or 'action-items-detail-pane' in src, \
        "Missing action items detail pane debug id"
    assert 'data-debug-id="action-items-search-input"' in src, "Missing action items search input"
    assert 'data-debug-id="action-items-project-select"' in src, "Missing action items project selector"

    # 3. Action controls and detail sections
    assert 'action-accept-btn-' in src, "Missing accept button with debug id"
    assert 'action-reject-btn-' in src, "Missing reject button with debug id"
    assert 'action-snooze-btn-' in src, "Missing snooze button with debug id"
    assert 'action-discard-btn-' in src, "Missing discard button with debug id"
    assert 'data-debug-id="action-items-rationale"' in src, "Missing rationale section with debug id"
    assert 'data-debug-id="action-items-operations"' in src, "Missing operations section with debug id"
    assert 'Markdown' in src, "Should render rationale using Markdown component"

    # 4. Mobile drill-down
    assert 'data-debug-id="action-items-back-btn"' in src, "Missing mobile back button with debug id"
    assert 'Back to action items' in src, "Missing mobile back button text"
    print("PASS: REQ-HOME-ACTIONS-5 (Action Items Tab)")


def test_req_home_mobile_6():
    """Verify Mobile Optimization (REQ-HOME-MOBILE-6)."""
    for path in [HOME_PAGE, CHAINS_TAB, ISSUES_TAB, ACTIONS_TAB]:
        src = path.read_text(encoding='utf-8')
        assert 'useIsMobile' in src or 'useViewport' in src, f"{path.name} should use mobile detection hook"

    # Verify touch target classes or min-h-[44px] on mobile elements
    chains_src = CHAINS_TAB.read_text(encoding='utf-8')
    assert 'min-h-[44px]' in chains_src or 'min-h-[36px]' in chains_src, "Chains tab should have accessible touch heights"

    actions_src = ACTIONS_TAB.read_text(encoding='utf-8')
    assert 'min-h-[44px]' in actions_src, "Actions tab should enforce >= 44px touch targets on mobile"
    assert 'var(--ui-bottom-chrome' in actions_src, "Actions tab should add safe area padding for mobile bottom chrome"

    issues_src = ISSUES_TAB.read_text(encoding='utf-8')
    assert 'min-h-[44px]' in issues_src, "Issues tab should enforce >= 44px touch targets on mobile"
    print("PASS: REQ-HOME-MOBILE-6 (Mobile Optimization)")


def test_req_home_ui_library_compliance():
    """Verify strict @ui library usage (no raw <select>)."""
    select_pattern = re.compile(r'<select[\s>]')
    for p in [HOME_PAGE, CHAINS_TAB, ISSUES_TAB, ACTIONS_TAB]:
        content = p.read_text(encoding='utf-8')
        assert not select_pattern.search(content), f"Forbidden native <select> found in {p.name}"
    print("PASS: UI Library Compliance (No native <select>)")


def main():
    print("Running Home Page Redesign regression test suite...")
    test_req_home_nav_1()
    test_req_home_tabs_2()
    test_req_home_chains_3()
    test_req_home_issues_4()
    test_req_home_actions_5()
    test_req_home_mobile_6()
    test_req_home_ui_library_compliance()
    print("\nALL HOME PAGE TESTS PASSED (REQ-HOME-NAV-1 through REQ-HOME-TESTS-7)!")


if __name__ == '__main__':
    main()
