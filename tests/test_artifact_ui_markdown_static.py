#!/usr/bin/env python3
"""Static regressions for artifact:// markdown links and artifact preview fallbacks."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MARKDOWN_BODY = ROOT / "src" / "ui" / "components" / "MarkdownBody.tsx"
ARTIFACT_VIEWER = ROOT / "src" / "ui" / "components" / "ArtifactViewer.tsx"
ARTIFACT_ENDPOINTS = ROOT / "src" / "ui" / "api" / "endpoints" / "artifacts.ts"
CHAIN_ARTIFACTS = ROOT / "src" / "ui" / "components" / "ChainArtifactsPanel.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    markdown = MARKDOWN_BODY.read_text(encoding="utf-8")
    viewer = ARTIFACT_VIEWER.read_text(encoding="utf-8")
    endpoints = ARTIFACT_ENDPOINTS.read_text(encoding="utf-8")
    chain_artifacts = CHAIN_ARTIFACTS.read_text(encoding="utf-8")

    pattern_match = re.search(r"export const ARTIFACT_ID_PATTERN = '([^']+)'", markdown)
    require(pattern_match is not None, "MarkdownBody should expose a shared artifact id pattern")
    artifact_id_pattern = pattern_match.group(1)
    artifact_uri_re = re.compile(rf"artifact://({artifact_id_pattern})")
    samples = {
        "open artifact://art_18c6c64699c0bd7e.": "art_18c6c64699c0bd7e",
        "(artifact://art_18c6c64699c0bd7e)": "art_18c6c64699c0bd7e",
        "artifact://art_18c6c64699c0bd7e,": "art_18c6c64699c0bd7e",
        "artifact://art_18c6c64699c0bd7e": "art_18c6c64699c0bd7e",
    }
    for text, expected in samples.items():
        match = artifact_uri_re.search(text)
        require(match is not None and match.group(1) == expected, f"artifact uri parser should ignore surrounding/trailing punctuation for {text!r}")
        require(match.group(0) == f"artifact://{expected}", f"artifact uri match should not include punctuation for {text!r}")

    require("ARTIFACT_MARKDOWN_LINK_RE" in markdown, "MarkdownBody should render [label](artifact://art_...) links as artifact chips")
    require("createArtifactButtonHtml(artifactId, label)" in markdown, "artifact markdown links should preserve a readable label before metadata loads")
    require("event.preventDefault();" in markdown, "artifact chip clicks should not bubble as ordinary links/buttons")

    require("normalizeArtifactRecord" in endpoints, "artifact endpoint layer should normalize artifact rows")
    require("stringField(row, 'mime', 'content_type', 'contentType')" in endpoints, "artifact normalization should accept content_type/contentType when mime is empty")
    require("normalizeArtifactResponse(await daemonApi.fetchArtifactMeta" in endpoints, "artifact metadata fetch should normalize daemon/hub response shapes")
    require("normalizeArtifactVersionsResponse(await daemonApi.fetchArtifactVersions" in endpoints, "artifact versions should normalize metadata fallback fields")
    require("Array.isArray(data?.data?.artifacts)" in endpoints, "artifact list normalization should accept nested agent-created list payloads")
    require("parsed?.data?.content" in endpoints, "text preview fetch should unwrap JSON content payloads when returned by artifact APIs")

    require("meta.content_type || meta.contentType" in viewer, "viewer preview classification should use content_type/contentType fallback")
    require("name.endsWith('.md')" in viewer and "name.endsWith('.markdown')" in viewer, "viewer should infer markdown preview from artifact name when ext/mime are empty")
    require("data-debug-id=\"artifact-viewer-versions-unavailable\"" in viewer, "viewer should keep preview/download available when version history is unavailable")
    require("versionsQuery.error\n      ? 'Failed to load retained artifact versions.'" not in viewer, "version history failure should not block artifact preview")

    require("row.mime || row.content_type || row.contentType" in chain_artifacts, "chain artifact library should display content_type fallback metadata")
    chain_project_list = "useListArtifactsQuery({ projectId, limit: 20 }" in chain_artifacts or "useListArtifactsQuery({ projectId, limit: 20, ...artifactRequestAuth }" in chain_artifacts
    require(chain_project_list, "artifact libraries should render backend project list results without origin-only scoping")

    # NOTE: the chat artifact side-panel assertions previously scanned
    # src/ui/components/App.tsx; they were dropped when that legacy component was
    # removed (dead code; the app mounts AppShell). MarkdownBody/ArtifactViewer/
    # endpoints/ChainArtifactsPanel coverage above remains authoritative.

    print("ARTIFACT UI MARKDOWN STATIC TEST PASSED")


if __name__ == "__main__":
    main()
