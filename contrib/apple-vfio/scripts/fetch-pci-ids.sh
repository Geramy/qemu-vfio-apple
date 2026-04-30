#!/bin/bash
#
# Fetch the latest pci.ids database from pci-ids.ucw.cz and cache it under
# the project's build-cache/ directory. Re-uses an existing copy if it's
# newer than $TTL_DAYS old (defaults to 7) so repeated builds don't hammer
# the upstream server.
#
# Usage:
#   fetch-pci-ids.sh [output-path]
#
# If output-path is omitted, the file is written to:
#   $SRCROOT/build-cache/pci.ids   (when run from Xcode)
#   <repo>/contrib/apple-vfio/build-cache/pci.ids  (when run standalone)
#
# Environment overrides:
#   PCI_IDS_URL    upstream URL (default: https://pci-ids.ucw.cz/v2.2/pci.ids)
#   PCI_IDS_TTL    cache age in days before re-fetch (default: 7)
#   PCI_IDS_FORCE  set to 1 to always re-download

set -euo pipefail

URL="${PCI_IDS_URL:-https://pci-ids.ucw.cz/v2.2/pci.ids}"
TTL_DAYS="${PCI_IDS_TTL:-7}"
FORCE="${PCI_IDS_FORCE:-0}"

if [ -n "${1:-}" ]; then
    OUT="$1"
elif [ -n "${SRCROOT:-}" ]; then
    OUT="$SRCROOT/build-cache/pci.ids"
else
    HERE="$(cd "$(dirname "$0")" && pwd)"
    OUT="$HERE/../build-cache/pci.ids"
fi

OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR"

needs_fetch=1
if [ "$FORCE" != "1" ] && [ -s "$OUT" ]; then
    # Re-use the cached copy if it's younger than TTL_DAYS.
    if find "$OUT" -mtime "-${TTL_DAYS}" -print -quit | grep -q .; then
        needs_fetch=0
    fi
fi

if [ "$needs_fetch" = "0" ]; then
    echo "fetch-pci-ids: using cached $OUT"
    exit 0
fi

TMP="$(mktemp "${OUT_DIR}/.pci.ids.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

echo "fetch-pci-ids: downloading $URL"
if ! curl --fail --silent --show-error --location \
        --connect-timeout 15 --max-time 120 \
        --output "$TMP" "$URL"; then
    if [ -s "$OUT" ]; then
        echo "fetch-pci-ids: download failed; keeping stale cache at $OUT" >&2
        exit 0
    fi
    echo "fetch-pci-ids: download failed and no cached copy available" >&2
    exit 1
fi

# Sanity check: file must contain at least one vendor entry header.
if ! head -c 8192 "$TMP" | grep -q "^[0-9a-f]\{4\}  "; then
    echo "fetch-pci-ids: downloaded file does not look like pci.ids" >&2
    exit 1
fi

mv "$TMP" "$OUT"
trap - EXIT
echo "fetch-pci-ids: wrote $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"
