#!/usr/bin/env python3
"""Static regression checks for Home task-chain name search/all-chain listing."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')
API = (ROOT / 'src/ui/api/daemonApi.ts').read_text(encoding='utf-8')


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAILED: {msg}')
        sys.exit(1)


require('const shownGroups = chainGroups;' in APP, 'home should receive all project chain groups, not selected-project filtered groups')
require('data-debug-id="home-chain-search-input"' in APP, 'home chain search input debug id missing')
require('data-debug-id="home-chain-search-count"' in APP, 'home chain search result count missing')
require('data-debug-id="home-chain-search-empty"' in APP, 'home chain search empty state missing')
require('function chainSearchName' in APP, 'chain name search helper missing')
require("chain?.title || chain?.name || chain?.chainId || ''" in APP, 'name search should use chain title/name with id fallback only')
require('chainSearchName(chain).includes(query)' in APP, 'home search should filter chains by name only')
require('chainSearchHaystack' not in APP, 'home search should not use broad metadata haystack')
for forbidden in [
    'task.assigneeAgentInstanceId',
    'task.reviewerAgentInstanceId',
    'group?.project?.name',
    'chain.coordinatorAgentInstanceId',
]:
    home_search_block = re.search(r'function normalizeChainSearchText[\s\S]+?function HomePage', APP)
    require(home_search_block and forbidden not in home_search_block.group(0), f'name-only search should not include {forbidden}')
require('Search by task-chain name.' in APP, 'home copy should describe name-only search')
require('placeholder="Search task-chain name"' in APP, 'home search placeholder should describe name-only search')
require('limit = 1000' in API and '/task-chains?limit=${limit}&offset=${offset}' in API, 'task chain API default limit should avoid truncating the home all-chains list')

home_block = re.search(r'function HomePage\([\s\S]+?function HomeRunningAgentsPanel', APP)
require(home_block is not None, 'HomePage block missing')
require('filteredGroups.map' in home_block.group(0), 'HomePage should render filtered groups')
require('groups.map' not in home_block.group(0).split('return (', 1)[-1], 'HomePage render should not bypass filtered groups')

print('HOME CHAIN SEARCH UI TEST PASSED')
