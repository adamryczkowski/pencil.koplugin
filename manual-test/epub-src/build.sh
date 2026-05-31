#!/usr/bin/env bash
# Build pencil-anchor-test.epub from the source tree.
# Run from this directory: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
OUT="../pencil-anchor-test.epub"
rm -f "$OUT"
# mimetype MUST be first and stored (not deflated) per EPUB spec.
zip -X0 "$OUT" mimetype >/dev/null
zip -Xr9D "$OUT" META-INF OEBPS >/dev/null
echo "Built $(realpath "$OUT") ($(wc -c < "$OUT") bytes)"
