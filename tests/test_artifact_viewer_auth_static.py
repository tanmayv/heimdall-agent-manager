#!/usr/bin/env python3
"""Static regressions for artifact viewer auth/session propagation.

The authenticated shell opens artifact routes with the ambient v1/cookie/device
session (daemonUrl='', clientToken='v1'). Artifact RTK Query endpoints must use
that per-request auth instead of stale legacy Redux chat.session values, or the
viewer shows "Failed to load artifact" for agent-created artifact:// links.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEIMDALL_API = (ROOT / "src/ui/api/heimdallApi.ts").read_text(encoding="utf-8")
ARTIFACT_ENDPOINTS = (ROOT / "src/ui/api/endpoints/artifacts.ts").read_text(encoding="utf-8")
ARTIFACT_VIEWER = (ROOT / "src/ui/components/ArtifactViewer.tsx").read_text(encoding="utf-8")
ARTIFACT_UPLOAD = (ROOT / "src/ui/components/ArtifactUpload.tsx").read_text(encoding="utf-8")
MARKDOWN = (ROOT / "src/ui/components/Markdown.tsx").read_text(encoding="utf-8")
LIBRARY = (ROOT / "src/ui/components/LibraryPage.tsx").read_text(encoding="utf-8")
CHAIN_ARTIFACTS = (ROOT / "src/ui/components/ChainArtifactsPanel.tsx").read_text(encoding="utf-8")
APP_SHELL = (ROOT / "src/ui/components/shell/AppShell.tsx").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# Query wrapper accepts explicit auth passed by shell-owned callers.
for marker in [
    "sessionWithRequestOverrides",
    "hasOwn(arg, 'daemonUrl')",
    "hasOwn(arg, 'clientToken')",
    "hasOwn(arg, 'clientInstanceId')",
]:
    require(marker in HEIMDALL_API, f"withSessionQuery missing override marker: {marker}")

# Artifact endpoint args carry those overrides, and mutation payloads strip them
# before calling daemonApi so auth(session) wins rather than being overwritten.
# Uploads without a legacy token in the cookie-auth web shell must also use the
# ambient relative /api/v1 route instead of an unauthenticated local daemon URL.
for marker in [
    "function isBrowserAmbientAuth()",
    "(!token && isBrowserAmbientAuth())",
    "type ArtifactAuthArgs",
    "type ArtifactListArgs = ArtifactAuthArgs &",
    "type ArtifactCreateArgs = ArtifactAuthArgs &",
    "type ArtifactUpdateArgs = ArtifactAuthArgs &",
    "type ArtifactTextContentArgs = ArtifactAuthArgs &",
    "fetchArtifactMeta: build.query<any, ArtifactAuthArgs & { artifactId: string }>",
    "fetchArtifactVersions: build.query<any, ArtifactAuthArgs & { artifactId: string }>",
    "function withoutArtifactAuthArgs",
    "daemonApi.createArtifact({ ...withoutArtifactAuthArgs(args), ...auth(session) })",
    "daemonApi.updateArtifact({ ...withoutArtifactAuthArgs(args), ...auth(session) })",
    "daemonApi.createArtifactAnnotation({ ...withoutArtifactAuthArgs(args), ...auth(session) })",
    "daemonApi.updateArtifactAnnotation({ ...withoutArtifactAuthArgs(args), ...auth(session) })",
    "daemonApi.deleteArtifactAnnotation({ ...withoutArtifactAuthArgs(args), ...auth(session) })",
]:
    require(marker in ARTIFACT_ENDPOINTS, f"artifact endpoint missing auth propagation marker: {marker}")

# Upload affordances should not reject AppShell cookie/device auth merely
# because legacy Redux chat.session has no clientToken.
for marker in [
    "function canUseAmbientArtifactAuth()",
    "Boolean((window as any).odinApi?.deviceAuth) || window.location.protocol === 'http:' || window.location.protocol === 'https:'",
    "function hasArtifactUploadAuth(session: any): boolean",
    "return canUseAmbientArtifactAuth() || Boolean(session?.daemonUrl && session?.clientToken)",
    "if (!hasArtifactUploadAuth(session))",
]:
    require(marker in ARTIFACT_UPLOAD, f"ArtifactUpload missing ambient auth marker: {marker}")

# Viewer must pass props through all artifact data/content calls, including
# markdown and code previews plus edit/delete/annotation mutations.
for marker in [
    "const artifactRequestAuth = useMemo(() => ({ daemonUrl, clientToken }), [daemonUrl, clientToken])",
    "useFetchArtifactMetaQuery({ artifactId, ...artifactRequestAuth }",
    "useFetchArtifactVersionsQuery({ artifactId, ...artifactRequestAuth }",
    "useFetchArtifactAnnotationsQuery(\n    { artifactId, versionNo: annotationScopeVersionNo, ...artifactRequestAuth }",
    "useFetchArtifactTextContentQuery(\n    { artifactId, versionNo: selectedVersionNo, ...artifactRequestAuth }",
    "function ArtifactCodePreview({ artifactId, versionNo, kind, daemonUrl, clientToken }",
    "useFetchArtifactTextContentQuery({ artifactId, versionNo, daemonUrl, clientToken }",
    "<ArtifactCodePreview artifactId={artifactId} versionNo={selectedVersionNo} kind={previewKind} {...artifactRequestAuth} />",
    "updateArtifactMutation({ artifactId, name, description: editDescription.trim(), changeReason: 'rename/description via viewer', ...artifactRequestAuth })",
    "deleteArtifactMutation({ artifactId, ...artifactRequestAuth })",
    "createAnnotationMutation({",
    "...artifactRequestAuth,",
]:
    require(marker in ARTIFACT_VIEWER, f"ArtifactViewer missing auth propagation marker: {marker}")

# Raw artifact:// chips rendered from markdown should open with ambient shell
# auth instead of stale legacy daemon/session values.
for marker in [
    "function canUseAmbientApiAuth()",
    "window.location.protocol === 'http:' || window.location.protocol === 'https:'",
    "return { daemonUrl: '', clientToken: 'v1' }",
    "const viewerSession = artifactViewerSession(session)",
    "<ArtifactViewer artifactId={activeArtifactId} daemonUrl={viewerSession.daemonUrl} clientToken={viewerSession.clientToken}",
]:
    require(marker in MARKDOWN, f"Markdown artifact link missing ambient auth marker: {marker}")

# Shell routes and list surfaces carry explicit artifact auth through the query
# layer so #/library/artifacts/<id> and libraries use the same ambient path.
require("<ArtifactViewer artifactId={decodeURIComponent(path.slice('/library/artifacts/'.length))} daemonUrl=\"\" clientToken=\"v1\"" in APP_SHELL,
        "AppShell artifact route should pass v1 ambient auth")
for source, name in [(LIBRARY, "LibraryPage"), (CHAIN_ARTIFACTS, "ChainArtifactsPanel")]:
    require("const artifactRequestAuth = useMemo(() => ({ daemonUrl, clientToken }), [daemonUrl, clientToken])" in source,
            f"{name} should memoize artifact auth props")
    require("useListArtifactsQuery({" in source and "...artifactRequestAuth" in source,
            f"{name} should pass artifact auth to list query")

print("PASS: artifact viewer auth propagation static checks")
