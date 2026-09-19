package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_artifact_page_cursor :: proc(t: ^testing.T) {
	artifact := domain.Artifact{
		artifact_id = "art_123",
		created_at  = "2026-03-01T10:00:00Z",
		updated_at  = "2026-03-02T15:30:00Z",
		name        = "my_artifact.txt",
		size_bytes  = 4096,
	}

	// created_at
	c_created := artifact_page_cursor(artifact, "created_at")
	testing.expect_value(t, c_created, "2026-03-01T10:00:00Z|art_123")

	// updated_at
	c_updated := artifact_page_cursor(artifact, "updated_at")
	testing.expect_value(t, c_updated, "2026-03-02T15:30:00Z|art_123")

	// default (empty)
	c_default := artifact_page_cursor(artifact, "")
	testing.expect_value(t, c_default, "2026-03-02T15:30:00Z|art_123")

	// name
	c_name := artifact_page_cursor(artifact, "name")
	testing.expect_value(t, c_name, "my_artifact.txt|art_123")

	// size_bytes
	c_size := artifact_page_cursor(artifact, "size_bytes")
	testing.expect_value(t, c_size, "4096|art_123")
}

@(test)
test_write_artifact_json_omits_content_when_false :: proc(t: ^testing.T) {
	artifact := domain.Artifact{
		artifact_id   = "art_456",
		name          = "report.md",
		content       = "SUPER_SECRET_LARGE_CONTENT",
		size_bytes    = 26,
		kind          = "file",
		content_type  = "text/markdown",
		created_at    = "2026-01-01T00:00:00Z",
		updated_at    = "2026-01-01T00:00:00Z",
	}

	// with_content = false
	b_no_content := strings.builder_make()
	defer strings.builder_destroy(&b_no_content)
	write_artifact_json(&b_no_content, artifact, false)
	out_no_content := strings.to_string(b_no_content)

	testing.expect(t, !strings.contains(out_no_content, "SUPER_SECRET_LARGE_CONTENT"), "must omit content body")
	testing.expect(t, !strings.contains(out_no_content, "\"content\":"), "must omit content key")
	testing.expect(t, strings.contains(out_no_content, "\"artifact_id\":\"art_456\""), "artifact_id present")
	testing.expect(t, strings.contains(out_no_content, "\"name\":\"report.md\""), "name present")
	testing.expect(t, strings.contains(out_no_content, "\"size_bytes\":26"), "size_bytes present")

	// with_content = true
	b_with_content := strings.builder_make()
	defer strings.builder_destroy(&b_with_content)
	write_artifact_json(&b_with_content, artifact, true)
	out_with_content := strings.to_string(b_with_content)

	testing.expect(t, strings.contains(out_with_content, "\"content\":\"SUPER_SECRET_LARGE_CONTENT\""), "content present when true")
}
