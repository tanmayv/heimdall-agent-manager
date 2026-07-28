#!/usr/bin/env python3
"""Static guard for UI-10: Library page + fullscreen Artifact viewer."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / "src" / "ui" / "components" / "LibraryPage.tsx"
VIEWER = ROOT / "src" / "ui" / "components" / "ArtifactViewer.tsx"
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
HOME_SLICE = ROOT / "src" / "ui" / "store" / "homeSlice.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    library = LIBRARY.read_text(encoding="utf-8")
    viewer = VIEWER.read_text(encoding="utf-8")
    app = APP.read_text(encoding="utf-8")
    home = HOME_SLICE.read_text(encoding="utf-8")
    daemon_api = (ROOT / "src" / "ui" / "api" / "daemonApi.ts").read_text(encoding="utf-8")

    # --- Library page structure ---
    for marker in [
        "library-page",
        "library-header",
        "library-title",
        "All artifacts across conversations, chains, and projects.",
        "library-view-toggle",
        "library-view-${mode}",
        "library-filters",
        "library-filter-search",
        "library-filter-kind",
        "library-filter-agent",
        "library-filter-project",
        "library-filter-chain",
        "library-grid",
        "library-list",
        "＋ Upload",
        "ArtifactViewer",
        "useListArtifactsQuery",
    ]:
        require(marker in library, f"LibraryPage missing: {marker}")
    # Grid (thumbnails) vs list (dense) both exist.
    require("library-card-" in library, "Library grid cards must have per-artifact debug ids")
    require("library-row-" in library, "Library list rows must have per-artifact debug ids")
    # Card/row click opens fullscreen viewer.
    require("setActiveArtifactId" in library, "Library card/row click must open the fullscreen ArtifactViewer")

    # --- Per-card rename + delete (PATCH / DELETE) ---
    for marker in [
        "library-card-rename-",
        "library-card-delete-",
        "useUpdateArtifactMutation",
        "useDeleteArtifactMutation",
        "rename from library",
        "unavailable placeholder",
    ]:
        require(marker in library, f"LibraryPage missing rename/delete: {marker}")

    # --- Artifact viewer: fullscreen overlay + kind-aware rendering ---
    for marker in [
        "fixed inset-0",
        "artifact-viewer",
        "artifact-viewer-breadcrumb",
        "artifact-viewer-meta-strip",
        "artifact-viewer-download-btn",
        "artifact-viewer-close-btn",
    ]:
        require(marker in viewer, f"ArtifactViewer missing: {marker}")

    # Kind-aware rendering: markdown/json/diff/text/image/binary fallback.
    for marker in [
        "MarkdownBody",
        "ArtifactCodePreview",
        "json",
        "diff",
        "text",
        "ZoomableImage",
        "artifact-viewer-image-preview",
        "artifact-viewer-unsupported-preview",
    ]:
        require(marker in viewer, f"ArtifactViewer missing kind-aware rendering: {marker}")
    # Image pinch-zoom/pan (touch + wheel/drag zoom on desktop).
    require("onTouchStart" in viewer and "onTouchMove" in viewer, "ArtifactViewer image must support touch pinch-zoom/pan")
    require("onWheel" in viewer, "ArtifactViewer image must support wheel zoom on desktop")
    require("artifact-viewer-zoomable-image" in viewer, "ArtifactViewer must render the zoomable image surface")

    # Rename / edit description (PATCH) + delete (DELETE) from viewer header.
    for marker in [
        "artifact-viewer-edit-meta-btn",
        "artifact-viewer-edit-meta-panel",
        "artifact-viewer-edit-name-input",
        "artifact-viewer-edit-description-input",
        "useUpdateArtifactMutation",
        "artifact-viewer-delete-btn",
        "artifact-viewer-delete-panel",
        "artifact-viewer-delete-confirm-btn",
        "useDeleteArtifactMutation",
    ]:
        require(marker in viewer, f"ArtifactViewer missing rename/delete: {marker}")

    # UI-10 correctness: rename/description + delete MUST hit the Hub rewrite
    # /api/v1 PATCH/DELETE routes (Bearer), NOT the legacy unserved
    # POST /artifacts/update or POST /artifacts/delete.
    require("`/api/v1/artifacts/${encodeURIComponent(artifactId)}`" in daemon_api
            and "method: 'PATCH'" in daemon_api,
            "daemonApi.updateArtifact must PATCH /api/v1/artifacts/{id} (Bearer)")
    require("`/api/v1/artifacts/${encodeURIComponent(artifactId)}`" in daemon_api
            and "method: 'DELETE'" in daemon_api,
            "daemonApi.deleteArtifact must DELETE /api/v1/artifacts/{id} (Bearer)")
    require("'/artifacts/update'" not in daemon_api,
            "daemonApi must not use legacy unserved POST /artifacts/update")
    require("'/artifacts/delete'" not in daemon_api,
            "daemonApi must not use legacy unserved POST /artifacts/delete")

    # --- App wiring: library surface + sidebar nav ---
    for marker in [
        "import LibraryPage",
        "home.surface === 'library'",
        "<LibraryPage",
        "onLibrary",
        "nav-library-btn",
        "onLibrary={() => selectSurfaceWithUrl('library')}",
    ]:
        require(marker in app, f"App.tsx missing library wiring: {marker}")

    # URL view -> surface mapping for 'library'.
    require("view === 'library'" in home, "homeSlice must map view='library' to the library surface")

    print("PASS: UI-10 library + artifact viewer static")


if __name__ == "__main__":
    main()
