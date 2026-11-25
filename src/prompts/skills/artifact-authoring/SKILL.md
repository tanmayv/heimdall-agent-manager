---
name: artifact-authoring
description: Deliver a report, image or static HTML site to the user as an artifact and link it as `artifact://<id>`: choose the format, write it, upload with `ham-ctl artifact create`, verify, deliver. Load when the user asks for a document, report, image or page, or when a result is too long or too visual for a chat message.
---

# Author artifacts for the user

An artifact is a file stored in the Hub (sealed with your vault key) that the user opens in the **Artifact Viewer**. Use one when a result is too long, too structured or too visual for a chat message, or when the user asks for a document, image or page. Bundle format and viewer rules: `docs/html-bundle-artifacts.md` in the Heimdall repository.

## 1. Choose the format

| The user needs | Use | `create` flags |
|---|---|---|
| A report, summary, plan, runbook, review, table of results | **Markdown** (the default) | `--kind markdown --file report.md` |
| A screenshot, chart, diagram or photo that already exists as a file | **Image** | `--kind image --content-type image/png --file chart.png` |
| Several linked pages, a styled layout, a document with images inline | **HTML bundle** | `--kind html-bundle --directory site` |
| A short answer, a status, a question | No artifact: a chat message | `ham-ctl chat send --to user --body …` |

Prefer the simplest format that works. Markdown renders headings, tables, code and Mermaid; use an HTML bundle only when layout, several pages or inline images matter. `--kind` defaults to `markdown`, so **always pass `--kind` for anything else**: the viewer picks its renderer from `kind` first, and an image uploaded without `--kind image` is shown as text. `--kind json` and `--kind diff` also have viewers.

## 2. Write it well

**Markdown**
- A standalone document: a `#` title, a one-paragraph summary first, then `##` sections. The reader has not seen your session: define terms, name files and ids in full.
- Tables for comparisons and results; fenced code blocks with a language for commands, code and logs; normal links for URLs.
- End-user content only: no tool chatter, "I ran…", scratch paths or attempt logs unless the reader asked.

**Images**
- Upload a file that already exists: a screenshot you captured, a chart from a plotting tool you actually have, a repository asset. If no image generator is available, say so and offer Markdown (a Mermaid diagram or a table); never claim to have generated an image you did not.
- Match `--content-type` to the real format (`image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/svg+xml`) and give a descriptive `--name` with that extension (`latency-p95-by-region.png`, not `image1.png`).
- Legible at phone width: large labels, sensible pixel size, screenshots cropped to what matters.

**HTML bundles** (static site in a sandboxed iframe)
- Local HTML, CSS, images and fonts only. **JavaScript never runs**: `.js`/`.mjs` stay in the downloaded ZIP, but scripts, `on*` handlers and `javascript:` URLs are removed from the preview, so pages must read correctly without script. **No remote URLs** (CDN stylesheets, web fonts and remote images are dropped and listed as warnings); no forms, iframes, objects or `<base>`. Inline the styling you need; use system font stacks or bundle font files.
- Relative paths everywhere (`assets/style.css`, `../index.html`, `#section`); `/x` means the bundle root; paths are case-sensitive.
- Entry page: a root `index.html`, or `--entry docs/index.html`. With several pages and no root `index.html`, `--entry` is required. A generated or supplied `heimdall-artifact.json` (`{"format_version":1,"entrypoint":…}`) names it; manifest entrypoint and `--entry` must agree if both are set; otherwise the entry is the root `index.html`, else the only HTML file.
- Responsive and readable: `<meta name="viewport" content="width=device-width, initial-scale=1">`, a max content width, `img { max-width: 100% }`, a nav linking every page.
- Allowed file types: `.html .htm .css .js .mjs .json .map .txt .md .xml .csv .webmanifest .png .jpg .jpeg .gif .webp .avif .bmp .ico .svg .woff .woff2 .ttf .otf .eot`. Anything else, including extensionless files like `LICENSE` or `.DS_Store`, is rejected: remove it.
- Limits: 15 MiB archive (15,728,640 bytes; `--directory` packs without compression, so roughly the sum of file sizes), 50 MiB expanded, 1000 files, 15 MiB per file; symlinks are skipped.

Before uploading a bundle, check every local reference resolves (run from the site root; prints nothing when all links are fine):

```bash
cd site && find . -name '*.html' -o -name '*.htm' -o -name '*.css' | while read -r f; do
  d=$(dirname "$f")
  grep -oE '(href|src)="[^"]+"|url\([^)]+\)' "$f" | sed -E 's/^(href|src)="//; s/"$//; s/^url\(["'"'"']?//; s/["'"'"']?\)$//' |
  grep -vE '^(#|data:|mailto:)' | sed 's/#.*//' | while read -r p; do
    case "$p" in http*|//*) echo "REMOTE (will be dropped): $f -> $p"; continue;; /*) t=".$p";; *) t="$d/$p";; esac
    [ -e "$t" ] || echo "MISSING: $f -> $p"
  done
done
```

## 3. Upload

```bash
# Markdown report, linked to your task so it shows with the task's artifacts
ham-ctl artifact create --name auth-review.md --kind markdown --file auth-review.md --task task_123

# Existing image file
ham-ctl artifact create --name latency-p95-by-region.png --kind image --content-type image/png --file out/latency.png

# Static site from a directory (index.html at its root); add --entry docs/index.html if the landing page is elsewhere
ham-ctl artifact create --name release-notes --kind html-bundle --directory ./site

# Prepared ZIP: zip from INSIDE the site so pages sit at the archive root
(cd site && zip -r ../site.zip .) && ham-ctl artifact create --name design-doc --kind html-bundle --file site.zip
```

- `artifact create --name <n> [--kind <k>] (--content <text> | --file <path> | --stdin)` makes a single-file artifact. For `html-bundle` give exactly one of `--directory` or `--file` (a ZIP holding the site at its root). Never use `--content` for large or binary payloads; use `--file`.
- Optional context flags: `--task <id>`, `--chain <id>`, `--project <id>`, `--description <t>`. The JSON reply carries `data.artifact_id` (`art_…`); keep it.
- Content is capped at 15 MiB (15,728,640 bytes of file or text before encryption; ham-ctl checks before sealing). MCP `artifacts.create`/`get` carry at most 64 KiB of text inline; use `ham-ctl artifact create --file` for anything larger.
- Read back: `artifact list [--kind <k>] [--project <id>] [--task <id>] [--chain <id>] [--limit <n>]`, `artifact show <id> [--with-content]`, `artifact content <id>`, `artifact download <id> --dir <dir>`.

## 4. Verify before you deliver
- Read the reply: `ok:true`, the expected `kind` and `content_type` (`text/markdown`, `image/png`, `application/zip` for bundles). For bundles read stderr: skipped symlinks are reported there.
- Round-trip it: `ham-ctl artifact content <art-id>` for text, or `ham-ctl artifact download <art-id> --dir <scratch-dir>` and compare with the source (`cmp`), or list a bundle's ZIP members to confirm `heimdall-artifact.json` and the entry.
- If the upload is wrong, fix the source and create a new artifact; deliver only the good id.

## 5. Deliver it
Put an `artifact://<art-id>` link in your message; chat and task-comment renderers turn it into a chip that opens the Artifact Viewer, and `[label](artifact://<art-id>)` labels the chip. There is no attachment flag on `chat send`.

```bash
ham-ctl chat send --to user --body "### Auth review ready

Summary: 2 blockers, 5 suggestions. Full report: [Auth review](artifact://art_18e2abc123)"

ham-ctl task comment task_123 --body "Report uploaded: artifact://art_18e2abc123"
```

Say in one or two lines what the artifact contains and what you want from the user (read, decide, approve). For task work, also reference the id in your `lease submit --summary` so reviewers and later tasks find it.
