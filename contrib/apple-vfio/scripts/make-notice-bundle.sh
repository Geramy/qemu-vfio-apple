#!/bin/bash
#
# Build a notice bundle to accompany binary distributions of VFIOUserHostApp
# when it embeds qemu-system-aarch64 and its third-party runtime dependencies.
#
# This generator creates a release-time notice bundle with:
#   - a manifest describing the bundled payload
#   - exact upstream license/COPYING files for each dependency
#   - source archive metadata for the fetched third-party license files
#
# It is intentionally a notice/source-link bundle only. It does not attempt
# to satisfy source-code delivery obligations by itself.
#
# Usage:
#   ./contrib/apple-vfio/scripts/make-notice-bundle.sh [output-dir] [dist-dir]
#
# Defaults:
#   output-dir: contrib/apple-vfio/release-notices
#   dist-dir:   dist
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

OUT_DIR="${1:-$REPO_ROOT/contrib/apple-vfio/release-notices}"
DIST_DIR="${2:-$REPO_ROOT/dist}"
LICENSE_DIR="$OUT_DIR/licenses"
DISPLAY_DIST="${DIST_DIR#$REPO_ROOT/}"
if [ "$DISPLAY_DIST" = "$DIST_DIR" ]; then
    DISPLAY_DIST="$DIST_DIR"
fi

log() {
    printf '[make-notice-bundle] %s\n' "$*"
}

artifact_lines() {
    local pattern="$1"
    local found=0
    local path

    shopt -s nullglob
    for path in $pattern; do
        found=1
        printf -- '%s\n' "- \`${path#$DIST_DIR/}\`"
    done
    shopt -u nullglob

    if [ "$found" -eq 0 ]; then
        printf -- "- _not present in %s_\n" "$DIST_DIR"
    fi
}

log "preparing output directory: $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$LICENSE_DIR/qemu" "$LICENSE_DIR/edk2"

log "copying local qemu/edk2 license material"
cp "$REPO_ROOT/COPYING" "$LICENSE_DIR/qemu/COPYING"
cp "$REPO_ROOT/pc-bios/edk2-licenses.txt" "$LICENSE_DIR/edk2/edk2-licenses.txt"

cat > "$LICENSE_DIR/qemu/SOURCE_INFO.txt" <<'EOF'
Component: qemu
Source-Type: local-repository
Repository: https://gitlab.com/qemu-project/qemu
Download-Page: https://www.qemu.org/download/
Notes: The bundled qemu-system-aarch64 binary is built from this repository.
EOF

cat > "$LICENSE_DIR/edk2/SOURCE_INFO.txt" <<'EOF'
Component: edk2
Source-Type: local-repository-reference
Repository: https://github.com/tianocore/edk2
Releases: https://github.com/tianocore/edk2/releases
Notes: The bundled firmware images are described by pc-bios/edk2-licenses.txt.
EOF

log "fetching upstream dependency license files"
python3 -u - "$LICENSE_DIR" <<'PY'
import io
import json
import os
import pathlib
import posixpath
import shutil
import subprocess
import sys
import tarfile
import time
from typing import Optional

license_root = pathlib.Path(sys.argv[1])

deps = [
    {
        "key": "bzip2",
        "formula": "bzip2",
        "files": ["LICENSE"],
    },
    {
        "key": "libffi",
        "formula": "libffi",
        "files": ["LICENSE"],
    },
    {
        "key": "libslirp",
        "formula": "libslirp",
        "files": ["COPYRIGHT"],
    },
    {
        "key": "glib",
        "formula": "glib",
        "files": [
            "COPYING",
            "gmodule/COPYING",
            "LICENSES/LGPL-2.1-or-later.txt",
        ],
    },
    {
        "key": "gmp",
        "formula": "gmp",
        "files": [
            "COPYING",
            "COPYING.LESSERv3",
            "COPYINGv2",
            "COPYINGv3",
        ],
    },
    {
        "key": "gnutls",
        "formula": "gnutls",
        "files": [
            "COPYING",
            "COPYING.LESSERv2",
        ],
    },
    {
        "key": "gettext-runtime",
        "formula": "gettext",
        "files": [
            "COPYING",
            "gettext-runtime/COPYING",
            "gettext-runtime/intl/COPYING.LIB",
        ],
    },
    {
        "key": "libiconv",
        "formula": "libiconv",
        "files": [
            "COPYING",
            "COPYING.LIB",
        ],
    },
    {
        "key": "libidn2",
        "formula": "libidn2",
        "files": [
            "COPYING",
            "COPYING.LESSERv3",
            "COPYING.unicode",
            "COPYINGv2",
        ],
    },
    {
        "key": "ncurses",
        "formula": "ncurses",
        "files": ["COPYING"],
    },
    {
        "key": "nettle",
        "formula": "nettle",
        "files": [
            "COPYING.LESSERv3",
            "COPYINGv2",
            "COPYINGv3",
        ],
    },
    {
        "key": "p11-kit",
        "formula": "p11-kit",
        "files": ["COPYING"],
    },
    {
        "key": "pcre2",
        "formula": "pcre2",
        "files": [
            "COPYING",
            "LICENCE.md",
        ],
    },
    {
        "key": "pixman",
        "formula": "pixman",
        "files": ["COPYING"],
    },
    {
        "key": "libpng",
        "formula": "libpng",
        "files": ["LICENSE"],
    },
    {
        "key": "libtasn1",
        "formula": "libtasn1",
        "files": [
            "COPYING",
            "COPYING.LESSERv2",
        ],
    },
    {
        "key": "libunistring",
        "formula": "libunistring",
        "files": [
            "COPYING",
            "COPYING.LIB",
        ],
    },
    {
        "key": "libusb",
        "formula": "libusb",
        "files": ["COPYING"],
    },
    {
        "key": "zlib",
        "formula": "zlib",
        "files": ["LICENSE"],
    },
    {
        "key": "zstd",
        "formula": "zstd",
        "files": [
            "COPYING",
            "LICENSE",
        ],
    },
]


def report(message: str) -> None:
    print(f"[make-notice-bundle] {message}", flush=True)


def fetch_bytes(url: str, label: str) -> bytes:
    report(f"downloading {label}: {url}")
    started = time.time()
    result = subprocess.run(
        [
            "curl",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--connect-timeout",
            "20",
            "--max-time",
            "120",
            "--user-agent",
            "qemu1-notice-bundle/1.0",
            url,
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    elapsed = time.time() - started
    report(
        f"downloaded {label}: {len(result.stdout)} bytes in {elapsed:.1f}s"
    )
    return result.stdout


def fetch_json(url: str) -> dict:
    return json.loads(fetch_bytes(url, "formula metadata").decode("utf-8"))


def member_relpath(name: str) -> str:
    parts = name.split("/", 1)
    return parts[1] if len(parts) == 2 else parts[0]


def resolve_member(archive: tarfile.TarFile, member: tarfile.TarInfo) -> Optional[tarfile.TarInfo]:
    seen = set()
    current = member

    while True:
        if current.name in seen:
            return None
        seen.add(current.name)

        if current.isfile():
            return current

        if current.issym() or current.islnk():
            base = posixpath.dirname(current.name)
            target = current.linkname
            if current.issym():
                target = posixpath.normpath(posixpath.join(base, target))
            try:
                current = archive.getmember(target)
            except KeyError:
                return None
            continue

        return None


for index, dep in enumerate(deps, start=1):
    formula = dep["formula"]
    report(f"[{index}/{len(deps)}] resolving {dep['key']} via formula {formula}")
    formula_info = fetch_json(f"https://formulae.brew.sh/api/formula/{formula}.json")
    source_url = formula_info["urls"]["stable"]["url"]
    archive_bytes = fetch_bytes(source_url, f"{dep['key']} source archive")

    target_dir = license_root / dep["key"]
    target_dir.mkdir(parents=True, exist_ok=True)

    found = {}
    archive_root = ""
    report(f"[{index}/{len(deps)}] extracting license files for {dep['key']}")
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:*") as archive:
        for member in archive.getmembers():
            if member.name:
                archive_root = member.name.split("/", 1)[0]
                break
        for member in archive.getmembers():
            relpath = member_relpath(member.name)
            if relpath not in dep["files"]:
                continue
            if relpath in found:
                continue

            resolved = resolve_member(archive, member)
            if resolved is None:
                continue

            destination = target_dir / relpath
            destination.parent.mkdir(parents=True, exist_ok=True)
            extracted = archive.extractfile(resolved)
            if extracted is None:
                continue
            with extracted, open(destination, "wb") as out:
                shutil.copyfileobj(extracted, out)
            found[relpath] = destination

    missing = [name for name in dep["files"] if name not in found]
    if missing:
        raise SystemExit(
            f"{dep['key']}: failed to extract expected license file(s): {', '.join(missing)}"
        )

    report(f"[{index}/{len(deps)}] writing metadata for {dep['key']}")
    with open(target_dir / "SOURCE_INFO.txt", "w", encoding="utf-8") as out:
        out.write(f"Component: {dep['key']}\n")
        out.write(f"Formula: {formula}\n")
        out.write(f"Homepage: {formula_info.get('homepage', '')}\n")
        out.write(f"Source-Archive: {source_url}\n")
        out.write(f"Source-Archive-Root: {archive_root}\n")
        out.write(f"License-Metadata: {formula_info.get('license', '')}\n")
        out.write("Fetched-Files:\n")
        for relpath in dep["files"]:
            out.write(f"  - {relpath}\n")

report("finished fetching dependency license files")
PY

log "writing THIRD_PARTY_NOTICES.md"
cat > "$OUT_DIR/THIRD_PARTY_NOTICES.md" <<EOF
# VFIOUserHostApp Third-Party Notices

This directory is a release-time notice bundle for binary distributions of
\`VFIOUserHostApp\` that embed QEMU binaries and the dependency payload produced
by \`contrib/apple-vfio/scripts/make-dist.sh\`.

It is intended to ship alongside a release artifact and contains:

- a manifest for the bundled runtime payload
- upstream license / COPYING files for each bundled dependency
- source archive metadata in \`licenses/*/SOURCE_INFO.txt\` for each fetched
  third-party dependency

## Included license directories

- \`licenses/qemu/\`
- \`licenses/edk2/\`
- \`licenses/bzip2/\`
- \`licenses/libffi/\`
- \`licenses/libslirp/\`
- \`licenses/glib/\`
- \`licenses/gmp/\`
- \`licenses/gnutls/\`
- \`licenses/gettext-runtime/\`
- \`licenses/libiconv/\`
- \`licenses/libidn2/\`
- \`licenses/ncurses/\`
- \`licenses/nettle/\`
- \`licenses/p11-kit/\`
- \`licenses/pcre2/\`
- \`licenses/pixman/\`
- \`licenses/libpng/\`
- \`licenses/libtasn1/\`
- \`licenses/libunistring/\`
- \`licenses/libusb/\`
- \`licenses/zlib/\`
- \`licenses/zstd/\`

## Release-specific reminder

Before publishing a binary release, record the exact source revision used for:

- this repository / QEMU build
- edk2 firmware images
- any prebuilt third-party library set, if the build does not resolve directly
  from source during release creation

## Bundled artifacts seen in \`$DISPLAY_DIST\`

EOF

if [ -d "$DIST_DIR/lib" ] || [ -f "$DIST_DIR/qemu-system-aarch64" ] || [ -d "$DIST_DIR/share/qemu" ]; then
    {
        printf -- "### Binary and library payload\n\n"
        artifact_lines "$DIST_DIR/qemu-system-aarch64"
        artifact_lines "$DIST_DIR/qemu-img"
        artifact_lines "$DIST_DIR/lib/*.dylib"
        printf -- "\n### Firmware and data payload\n\n"
        artifact_lines "$DIST_DIR/share/qemu/*"
        printf -- "\n"
    } >> "$OUT_DIR/THIRD_PARTY_NOTICES.md"
else
    cat >> "$OUT_DIR/THIRD_PARTY_NOTICES.md" <<EOF
No \`dist/\` directory was found when this bundle was generated, so the component
list below is based on the current expected payload rather than a live scan.

EOF
fi

cat >> "$OUT_DIR/THIRD_PARTY_NOTICES.md" <<'EOF'
## Component notices

### QEMU

- Distributed artifacts:
  - `qemu-system-aarch64`
  - `qemu-img`
  - `share/qemu/descriptors/*`
  - `share/qemu/keymaps/*` when present
  - additional data files copied from `pc-bios/` when present
- License: `GPL-2.0-only`
- Bundled license files: `licenses/qemu/`
- Upstream source:
  - <https://gitlab.com/qemu-project/qemu>
  - <https://www.qemu.org/download/>

### edk2 firmware images

- Distributed artifacts:
  - `share/qemu/edk2-*`
  - `share/qemu/efi-*.rom`
  - matching firmware descriptor JSON files in `share/qemu/descriptors/`
- License: `BSD-2-Clause-Patent`
- Bundled license files: `licenses/edk2/`
- Upstream source:
  - <https://github.com/tianocore/edk2>
  - <https://github.com/tianocore/edk2/releases>

### bzip2

- Distributed artifacts:
  - `lib/libbz2.1.0.8.dylib`
- License: `bzip2-1.0.6`
- Bundled license files: `licenses/bzip2/`
- Upstream source:
  - `licenses/bzip2/SOURCE_INFO.txt`

### libffi

- Distributed artifacts:
  - `lib/libffi.8.dylib`
- License: `MIT`
- Bundled license files: `licenses/libffi/`
- Upstream source:
  - `licenses/libffi/SOURCE_INFO.txt`

### libslirp

- Distributed artifacts:
  - `lib/libslirp.0.dylib`
- License: `BSD-3-Clause`
- Bundled license files: `licenses/libslirp/`
- Upstream source:
  - `licenses/libslirp/SOURCE_INFO.txt`

### GLib family

- Distributed artifacts:
  - `lib/libglib-2.0.0.dylib`
  - `lib/libgobject-2.0.0.dylib`
  - `lib/libgio-2.0.0.dylib`
  - `lib/libgmodule-2.0.0.dylib`
- License: `LGPL-2.1-or-later`
- Bundled license files: `licenses/glib/`
- Upstream source:
  - `licenses/glib/SOURCE_INFO.txt`

### GMP

- Distributed artifacts:
  - `lib/libgmp.10.dylib`
- License used for the bundled library: `LGPL-3.0-or-later`
- Bundled license files: `licenses/gmp/`
- Upstream source:
  - `licenses/gmp/SOURCE_INFO.txt`

### GnuTLS

- Distributed artifacts:
  - `lib/libgnutls.30.dylib`
- License used for the bundled library: `LGPL-2.1-or-later`
- Bundled license files: `licenses/gnutls/`
- Upstream source:
  - `licenses/gnutls/SOURCE_INFO.txt`

### gettext runtime (`libintl`)

- Distributed artifacts:
  - `lib/libintl.8.dylib`
- License used for the bundled runtime library: `LGPL-2.1-or-later`
- Bundled license files: `licenses/gettext-runtime/`
- Upstream source:
  - `licenses/gettext-runtime/SOURCE_INFO.txt`

### GNU libiconv

- Distributed artifacts:
  - `lib/libiconv.2.dylib`
- License used for the bundled library: `LGPL-2.0-or-later`
- Bundled license files: `licenses/libiconv/`
- Upstream source:
  - `licenses/libiconv/SOURCE_INFO.txt`

### libidn2

- Distributed artifacts:
  - `lib/libidn2.0.dylib`
- License used for the bundled library: `LGPL-3.0-or-later`
- Note: libidn2 also incorporates Unicode data files with additional Unicode
  license notices in its upstream source distribution.
- Bundled license files: `licenses/libidn2/`
- Upstream source:
  - `licenses/libidn2/SOURCE_INFO.txt`

### ncurses

- Distributed artifacts:
  - `lib/libncursesw.6.dylib`
- License: X11-style / ncurses license
- Bundled license files: `licenses/ncurses/`
- Upstream source:
  - `licenses/ncurses/SOURCE_INFO.txt`

### nettle / hogweed

- Distributed artifacts:
  - `lib/libnettle.8.11.dylib`
  - `lib/libhogweed.6.11.dylib`
- License used for the bundled libraries: `LGPL-3.0-or-later`
- Bundled license files: `licenses/nettle/`
- Upstream source:
  - `licenses/nettle/SOURCE_INFO.txt`

### p11-kit

- Distributed artifacts:
  - `lib/libp11-kit.0.dylib`
- License: `BSD-3-Clause`
- Bundled license files: `licenses/p11-kit/`
- Upstream source:
  - `licenses/p11-kit/SOURCE_INFO.txt`

### PCRE2

- Distributed artifacts:
  - `lib/libpcre2-8.0.dylib`
- License: `BSD-3-Clause`
- Bundled license files: `licenses/pcre2/`
- Upstream source:
  - `licenses/pcre2/SOURCE_INFO.txt`

### pixman

- Distributed artifacts:
  - `lib/libpixman-1.0.40.0.dylib`
- License: `MIT`
- Bundled license files: `licenses/pixman/`
- Upstream source:
  - `licenses/pixman/SOURCE_INFO.txt`

### libpng

- Distributed artifacts:
  - `lib/libpng16.16.dylib`
- License: `libpng-2.0`
- Bundled license files: `licenses/libpng/`
- Upstream source:
  - `licenses/libpng/SOURCE_INFO.txt`

### libtasn1

- Distributed artifacts:
  - `lib/libtasn1.6.dylib`
- License: `LGPL-2.1-or-later`
- Bundled license files: `licenses/libtasn1/`
- Upstream source:
  - `licenses/libtasn1/SOURCE_INFO.txt`

### libunistring

- Distributed artifacts:
  - `lib/libunistring.5.dylib`
- License used for the bundled library: `LGPL-3.0-or-later`
- Bundled license files: `licenses/libunistring/`
- Upstream source:
  - `licenses/libunistring/SOURCE_INFO.txt`

### libusb

- Distributed artifacts:
  - `lib/libusb-1.0.0.dylib`
- License: `LGPL-2.1-or-later`
- Bundled license files: `licenses/libusb/`
- Upstream source:
  - `licenses/libusb/SOURCE_INFO.txt`

### zlib

- Distributed artifacts:
  - `lib/libz.1.3.1.dylib`
- License: `Zlib`
- Bundled license files: `licenses/zlib/`
- Upstream source:
  - `licenses/zlib/SOURCE_INFO.txt`

### zstd

- Distributed artifacts:
  - `lib/libzstd.1.5.7.dylib`
- License used for the bundled library: `BSD-3-Clause`
- Bundled license files: `licenses/zstd/`
- Upstream source:
  - `licenses/zstd/SOURCE_INFO.txt`
EOF

log "wrote notice bundle to: $OUT_DIR"
