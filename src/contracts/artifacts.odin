package contracts

import "core:strings"

Artifact_ID :: distinct string

Artifact_Metadata :: struct {
	artifact_id:        Artifact_ID,
	name:               string,
	kind:               string,
	mime:               string,
	ext:                string,
	size_bytes:         i64,
	sha256:             string,
	description:        string,
	project_id:         string,
	creator_type:       string,
	creator_id:         string,
	origin_kind:        string,
	origin_ref:         string,
	current_version_no: i64,
	created_unix_ms:    i64,
	updated_unix_ms:    i64,
	deleted:            bool,
}

Artifact_Version :: struct {
	artifact_id:      Artifact_ID,
	version_no:       i64,
	name:             string,
	kind:             string,
	mime:             string,
	ext:              string,
	size_bytes:       i64,
	sha256:           string,
	description:      string,
	project_id:       string,
	origin_kind:      string,
	origin_ref:       string,
	author_type:      string,
	author_id:        string,
	change_reason:    string,
	created_unix_ms:  i64,
}

Artifact_Annotation :: struct {
	annotation_id:    string,
	artifact_id:      Artifact_ID,
	version_no:       i64,
	author_type:      string,
	author_id:        string,
	context_type:     string,
	context_json:     string,
	comment:          string,
	created_unix_ms:  i64,
	updated_unix_ms:  i64,
	deleted:          bool,
	deleted_unix_ms:  i64,
}

Artifact_Type_Validation :: struct {
	kind: string,
	mime: string,
	ext:  string,
}

ARTIFACT_SCHEME :: "artifact://"
ARTIFACT_ID_PREFIX :: "art_"
ARTIFACT_MAX_VERSIONS :: 5

ROUTE_ARTIFACTS_PREFIX :: "/artifacts"
ROUTE_ARTIFACTS_CREATE :: "/artifacts/create"
ROUTE_ARTIFACTS_UPDATE :: "/artifacts/update"
ROUTE_ARTIFACTS_DELETE :: "/artifacts/delete"
ROUTE_ARTIFACTS_ROLLBACK :: "/artifacts/rollback"
ROUTE_ARTIFACTS_CONTENT_SUFFIX :: "/content"
ROUTE_ARTIFACTS_VERSIONS_SUFFIX :: "/versions"
ROUTE_ARTIFACTS_ANNOTATIONS_PREFIX :: "/artifacts/annotations"
ROUTE_ARTIFACTS_ANNOTATIONS_SUFFIX :: "/annotations"
ROUTE_ARTIFACTS_ANNOTATIONS_CREATE :: "/artifacts/annotations/create"
ROUTE_ARTIFACTS_ANNOTATIONS_UPDATE :: "/artifacts/annotations/update"
ROUTE_ARTIFACTS_ANNOTATIONS_DELETE :: "/artifacts/annotations/delete"

ARTIFACT_ANNOTATION_CONTEXT_TEXT :: "text"
ARTIFACT_ANNOTATION_CONTEXT_IMAGE :: "image"

ARTIFACT_KIND_MARKDOWN :: "markdown"
ARTIFACT_KIND_PNG      :: "png"
ARTIFACT_KIND_JPEG     :: "jpeg"
ARTIFACT_KIND_CSV      :: "csv"
ARTIFACT_KIND_HTML     :: "html"

ARTIFACT_MIME_MARKDOWN :: "text/markdown"
ARTIFACT_MIME_PNG      :: "image/png"
ARTIFACT_MIME_JPEG     :: "image/jpeg"
ARTIFACT_MIME_CSV      :: "text/csv"
ARTIFACT_MIME_HTML     :: "text/html"

ARTIFACT_RENDERER_MARKDOWN :: "markdown"
ARTIFACT_RENDERER_IMAGE    :: "image"
ARTIFACT_RENDERER_CSV      :: "csv"
ARTIFACT_RENDERER_HTML     :: "html"

ARTIFACT_SUPPORTED_KINDS :: [5]string{
	ARTIFACT_KIND_MARKDOWN,
	ARTIFACT_KIND_PNG,
	ARTIFACT_KIND_JPEG,
	ARTIFACT_KIND_CSV,
	ARTIFACT_KIND_HTML,
}

artifact_normalize_kind :: proc(kind: string) -> string {
	return strings.to_lower(strings.trim_space(kind))
}

artifact_normalize_mime :: proc(mime: string) -> string {
	return strings.to_lower(strings.trim_space(mime))
}

artifact_normalize_ext :: proc(ext: string) -> string {
	normalized := strings.to_lower(strings.trim_space(ext))
	if normalized == "" do return ""
	if !strings.has_prefix(normalized, ".") do return strings.concatenate({".", normalized})
	return normalized
}

artifact_kind_supported :: proc(kind: string) -> bool {
	switch artifact_normalize_kind(kind) {
	case ARTIFACT_KIND_MARKDOWN, ARTIFACT_KIND_PNG, ARTIFACT_KIND_JPEG, ARTIFACT_KIND_CSV, ARTIFACT_KIND_HTML:
		return true
	case:
		return false
	}
}

artifact_kind_mime :: proc(kind: string) -> string {
	switch artifact_normalize_kind(kind) {
	case ARTIFACT_KIND_MARKDOWN:
		return ARTIFACT_MIME_MARKDOWN
	case ARTIFACT_KIND_PNG:
		return ARTIFACT_MIME_PNG
	case ARTIFACT_KIND_JPEG:
		return ARTIFACT_MIME_JPEG
	case ARTIFACT_KIND_CSV:
		return ARTIFACT_MIME_CSV
	case ARTIFACT_KIND_HTML:
		return ARTIFACT_MIME_HTML
	case:
		return ""
	}
}

artifact_kind_primary_ext :: proc(kind: string) -> string {
	switch artifact_normalize_kind(kind) {
	case ARTIFACT_KIND_MARKDOWN:
		return ".md"
	case ARTIFACT_KIND_PNG:
		return ".png"
	case ARTIFACT_KIND_JPEG:
		return ".jpg"
	case ARTIFACT_KIND_CSV:
		return ".csv"
	case ARTIFACT_KIND_HTML:
		return ".html"
	case:
		return ""
	}
}

artifact_kind_renderer :: proc(kind: string) -> string {
	switch artifact_normalize_kind(kind) {
	case ARTIFACT_KIND_MARKDOWN:
		return ARTIFACT_RENDERER_MARKDOWN
	case ARTIFACT_KIND_PNG, ARTIFACT_KIND_JPEG:
		return ARTIFACT_RENDERER_IMAGE
	case ARTIFACT_KIND_CSV:
		return ARTIFACT_RENDERER_CSV
	case ARTIFACT_KIND_HTML:
		return ARTIFACT_RENDERER_HTML
	case:
		return ""
	}
}

artifact_kind_supports_extension :: proc(kind, ext: string) -> bool {
	normalized_kind := artifact_normalize_kind(kind)
	normalized_ext := artifact_normalize_ext(ext)
	switch normalized_kind {
	case ARTIFACT_KIND_MARKDOWN:
		return normalized_ext == ".md"
	case ARTIFACT_KIND_PNG:
		return normalized_ext == ".png"
	case ARTIFACT_KIND_JPEG:
		return normalized_ext == ".jpg" || normalized_ext == ".jpeg"
	case ARTIFACT_KIND_CSV:
		return normalized_ext == ".csv"
	case ARTIFACT_KIND_HTML:
		return normalized_ext == ".html" || normalized_ext == ".htm"
	case:
		return false
	}
}

artifact_kind_supports_mime :: proc(kind, mime: string) -> bool {
	return artifact_kind_mime(kind) == artifact_normalize_mime(mime)
}

artifact_validate_kind_mime_ext :: proc(kind, mime, ext: string) -> (Artifact_Type_Validation, bool) {
	normalized_kind := artifact_normalize_kind(kind)
	normalized_mime := artifact_normalize_mime(mime)
	normalized_ext := artifact_normalize_ext(ext)
	if !artifact_kind_supported(normalized_kind) do return Artifact_Type_Validation{}, false
	if normalized_mime == "" || normalized_ext == "" do return Artifact_Type_Validation{}, false
	if !artifact_kind_supports_mime(normalized_kind, normalized_mime) do return Artifact_Type_Validation{}, false
	if !artifact_kind_supports_extension(normalized_kind, normalized_ext) do return Artifact_Type_Validation{}, false
	return Artifact_Type_Validation{kind = normalized_kind, mime = normalized_mime, ext = normalized_ext}, true
}

artifact_make_link :: proc(artifact_id: string) -> string {
	return strings.concatenate({ARTIFACT_SCHEME, artifact_id})
}

artifact_parse_link :: proc(link: string) -> (string, bool) {
	if !strings.has_prefix(link, ARTIFACT_SCHEME) do return "", false
	artifact_id := link[len(ARTIFACT_SCHEME):]
	if !artifact_id_valid(artifact_id) do return "", false
	return artifact_id, true
}

artifact_id_valid :: proc(artifact_id: string) -> bool {
	if !strings.has_prefix(artifact_id, ARTIFACT_ID_PREFIX) do return false
	suffix := artifact_id[len(ARTIFACT_ID_PREFIX):]
	if len(suffix) < 8 do return false
	for ch in suffix {
		switch ch {
		case '0'..='9', 'a'..='f':
		case:
			return false
		}
	}
	return true
}

artifact_kind_matches_magic_bytes :: proc(kind: string, data: []byte) -> bool {
	switch artifact_normalize_kind(kind) {
	case ARTIFACT_KIND_PNG:
		return artifact_is_png_bytes(data)
	case ARTIFACT_KIND_JPEG:
		return artifact_is_jpeg_bytes(data)
	case:
		return true
	}
}

artifact_detect_image_kind_from_magic_bytes :: proc(data: []byte) -> string {
	if artifact_is_png_bytes(data) do return ARTIFACT_KIND_PNG
	if artifact_is_jpeg_bytes(data) do return ARTIFACT_KIND_JPEG
	return ""
}

artifact_is_png_bytes :: proc(data: []byte) -> bool {
	return len(data) >= 8 &&
		data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4e && data[3] == 0x47 &&
		data[4] == 0x0d && data[5] == 0x0a && data[6] == 0x1a && data[7] == 0x0a
}

artifact_is_jpeg_bytes :: proc(data: []byte) -> bool {
	return len(data) >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff
}
