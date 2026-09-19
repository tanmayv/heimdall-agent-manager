#!/usr/bin/env python3
"""Static guard for UI-10: Library page + fullscreen Artifact viewer."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / "src" / "ui" / "components" / "LibraryPage.tsx"
VIEWER = ROOT / "src" / "ui" / "components" / "ArtifactViewer.tsx"
HOME_SLICE = ROOT / "src" / "ui" / "store" / "homeSlice.ts"

EMOJI_PATTERN = re.compile(
    r"[\U0001F600-\U0001F64F"  # emoticons
    r"\U0001F300-\U0001F5FF"  # symbols & pictographs
    r"\U0001F680-\U0001F6FF"  # transport & map
    r"\U0001F1E0-\U0001F1FF"  # flags
    r"\U00002702-\U000027B0"
    r"\U000024C2-\U0001F251"
    r"\U0001F900-\U0001F9FF"  # supplemental symbols
    r"\U0001FA70-\U0001FAFF"  # symbols and pictographs extended-a
    r"\u2600-\u26FF"          # miscellaneous symbols
    r"\u2700-\u27BF"          # dingbats
    r"📝🧾🖼📎✎🗑🌍]"         # specific emoji glyphs
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    library = LIBRARY.read_text(encoding="utf-8")
    viewer = VIEWER.read_text(encoding="utf-8")
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
        "ArtifactViewer",
        "useListArtifactsQuery",
    ]:
        require(marker in library, f"LibraryPage missing: {marker}")

    # Upload button removed from LibraryPage.tsx (REQ-UI-LIBRARY-REMOVE-UPLOAD)
    require("ArtifactUploadButton" not in library, "LibraryPage must not contain ArtifactUploadButton")
    require("library-upload" not in library, "LibraryPage must not contain upload debug id")
    require("＋ Upload" not in library, "LibraryPage must not contain upload label")
    require("useArtifactUpload" not in library, "LibraryPage must not contain useArtifactUpload hook")

    # KIND_ICON emojis removed; replaced with @ui Icon glyphs
    require("KIND_ICON" not in library, "LibraryPage must not contain KIND_ICON emoji map")

    # Zero emojis enforced across LibraryPage and ArtifactViewer (REQ-UI-NO-EMOJIS)
    library_emojis = EMOJI_PATTERN.findall(library)
    require(len(library_emojis) == 0, f"LibraryPage contains emojis: {library_emojis}")
    viewer_emojis = EMOJI_PATTERN.findall(viewer)
    require(len(viewer_emojis) == 0, f"ArtifactViewer contains emojis: {viewer_emojis}")

    # Grid (thumbnails) vs list (dense) both exist.
    require("library-card-" in library, "Library grid cards must have per-artifact debug ids")
    require("library-row-" in library, "Library list rows must have per-artifact debug ids")
    # Card/row click opens fullscreen viewer.
    require("setActiveArtifactId" in library, "Library card/row click must open the fullscreen ArtifactViewer")

    # --- Per-card rename + delete (PATCH / DELETE) in LibraryPage ---
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
        "artifact-viewer-copy-link-btn",
        "artifact-viewer-download-btn",
        "artifact-viewer-close-btn",
    ]:
        require(marker in viewer, f"ArtifactViewer missing: {marker}")

    # Strictly THREE action buttons present in ArtifactViewer (REQ-UI-ARTIFACT-PREVIEW-BUTTONS)
    require("Copy Link" in viewer, "ArtifactViewer must have 'Copy Link' button")
    require("Download" in viewer, "ArtifactViewer must have 'Download' button")
    require("Close" in viewer, "ArtifactViewer must have 'Close' button")

    # Absence of removed action buttons and annotation subsystems (REQ-UI-ARTIFACT-PREVIEW-BUTTONS, REQ-UI-ARTIFACT-REMOVE-ANNOTATIONS)
    for banned in [
        "artifact-viewer-edit-meta-btn",
        "artifact-viewer-edit-meta-panel",
        "artifact-viewer-edit-name-input",
        "artifact-viewer-edit-description-input",
        "artifact-viewer-delete-btn",
        "artifact-viewer-delete-panel",
        "artifact-viewer-delete-confirm-btn",
        "artifact-viewer-rollback-btn",
        "artifact-viewer-annotate-toggle",
        "artifact-viewer-annotations-panel",
        "artifact-viewer-copy-all-annotations-btn",
        "RegionAnnotationLayer",
        "AnnotationListItem",
        "useFetchArtifactAnnotationsQuery",
        "useCreateArtifactAnnotationMutation",
        "useUpdateArtifactAnnotationMutation",
        "useDeleteArtifactAnnotationMutation",
        "artifact-viewer-png-annotation-layer",
        "artifact-viewer-png-annotation-panel",
        "artifact-viewer-text-selection-summary",
    ]:
        require(banned not in viewer, f"ArtifactViewer must not contain removed feature/element: {banned}")

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
    # Image pinch-zoom/pan (touch + wheel/drag zoom on desktop) standardized for all images.
    require("onTouchStart" in viewer and "onTouchMove" in viewer, "ArtifactViewer image must support touch pinch-zoom/pan")
    require("onWheel" in viewer, "ArtifactViewer image must support wheel zoom on desktop")
    require("artifact-viewer-zoomable-image" in viewer, "ArtifactViewer must render the zoomable image surface")

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

    # URL view -> surface mapping for 'library'.
    require("view === 'library'" in home, "homeSlice must map view='library' to the library surface")

    print("PASS: UI-10 library + artifact viewer static")


if __name__ == "__main__":
    main()
