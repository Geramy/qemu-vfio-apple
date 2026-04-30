#!/bin/bash
#
# Bundle qemu-system-aarch64 and related QEMU tools with all their non-system
# dylib dependencies into a self-contained dist/ directory. Lives under the
# apple-vfio contrib because the resulting layout (single dist/ tree with
# @executable_path-rewritten dylibs in lib/) is shaped specifically for the
# VFIOUserHostApp .app bundle that embeds it.
#
# Run from the qemu source root:
#
#   ./contrib/apple-vfio/scripts/make-dist.sh [build-dir] [dist-dir]
#
# build-dir defaults to ./build, dist-dir to ./dist. The script reads
# accel/hvf/entitlements.plist relative to the current directory, so the
# CWD must be the qemu source root regardless of where this script lives
# on disk.
#
# Codesigning:
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#       ./contrib/apple-vfio/scripts/make-dist.sh
#
# Notarization (after signing with Developer ID):
#   NOTARIZE=1 APPLE_ID=you@example.com TEAM_ID=TEAMID \
#       ./contrib/apple-vfio/scripts/make-dist.sh
#
set -euo pipefail

BUILD_DIR="${1:-build}"
DIST_DIR="${2:-dist}"
MAIN_BINARY="$BUILD_DIR/qemu-system-aarch64"
REQUIRED_BINARIES="qemu-img"
ENTITLEMENTS="accel/hvf/entitlements.plist"

# Codesigning identity: "-" for ad-hoc, or "Developer ID Application: ..." for distribution
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

if [ ! -f "$MAIN_BINARY" ]; then
    echo "error: $MAIN_BINARY not found" >&2
    exit 1
fi

for tool in $REQUIRED_BINARIES; do
    src="$BUILD_DIR/$tool"
    if [ ! -f "$src" ]; then
        echo "error: required tool $src not found" >&2
        exit 1
    fi
done

WORK=$(mktemp -d)
trap "rm -rf '$WORK'" EXIT

# Simple key-value stores (bash 3 compatible, no associative arrays)
SEEN_FILE="$WORK/seen"        # one realpath per line
LIBMAP_FILE="$WORK/libmap"    # realpath<TAB>basename
ORIGDIR_FILE="$WORK/origdir"  # basename<TAB>original_dir (for @loader_path resolution)
QUEUE_FILE="$WORK/queue"
RPATHS_FILE="$WORK/rpaths"

touch "$SEEN_FILE" "$LIBMAP_FILE" "$ORIGDIR_FILE" "$QUEUE_FILE" "$RPATHS_FILE"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_system_lib() {
    case "$1" in
        /System/*|/usr/lib/*) return 0 ;;
        *) return 1 ;;
    esac
}

get_rpaths() {
    otool -l "$1" 2>/dev/null \
        | awk '/cmd LC_RPATH/{found=1} found && /path /{print $2; found=0}'
}

normalize_rpath() {
    local rp="$1"
    local loader_dir="$2"

    case "$rp" in
        @loader_path/*)
            local suffix="${rp#@loader_path/}"
            local candidate="$loader_dir/$suffix"
            if [ -d "$candidate" ]; then
                (cd "$candidate" 2>/dev/null && pwd)
                return 0
            fi
            ;;
        @executable_path/*)
            local suffix="${rp#@executable_path/}"
            local candidate="$loader_dir/$suffix"
            if [ -d "$candidate" ]; then
                (cd "$candidate" 2>/dev/null && pwd)
                return 0
            fi
            ;;
        /*)
            if [ -d "$rp" ]; then
                (cd "$rp" 2>/dev/null && pwd)
                return 0
            fi
            ;;
    esac

    return 1
}

is_seen() {
    grep -qFx "$1" "$SEEN_FILE" 2>/dev/null
}

mark_seen() {
    echo "$1" >> "$SEEN_FILE"
}

set_libmap() {
    printf '%s\t%s\n' "$1" "$2" >> "$LIBMAP_FILE"
}

get_libmap() {
    awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$LIBMAP_FILE"
}

set_origdir() {
    # $1=basename $2=original_directory
    printf '%s\t%s\n' "$1" "$2" >> "$ORIGDIR_FILE"
}

get_origdir() {
    awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$ORIGDIR_FILE"
}

# Resolve a bare dylib leaf within common pkgx layouts.
resolve_pkgx_leaf() {
    local leaf="$1"
    local candidate

    [ -n "${HOME:-}" ] || return 1

    shopt -s nullglob
    for candidate in \
        "$HOME/.pkgx"/*/*/lib/"$leaf" \
        "$HOME/.pkgx"/*/*/*/lib/"$leaf" \
        "$HOME/.pkgx"/*/*/*/*/lib/"$leaf"
    do
        [ -f "$candidate" ] || continue
        realpath "$candidate"
        shopt -u nullglob
        return 0
    done
    shopt -u nullglob

    return 1
}

# Resolve an install-name reference to a realpath.
resolve_ref() {
    local ref="$1"
    local loader_dir="$2"
    shift 2

    case "$ref" in
        @rpath/*)
            local suffix="${ref#@rpath/}"
            local leaf="$(basename "$suffix")"
            for rp in "$@"; do
                local norm
                norm="$(normalize_rpath "$rp" "$loader_dir")" || continue
                local candidate="$norm/$suffix"
                if [ -f "$candidate" ]; then
                    realpath "$candidate"
                    return 0
                fi
                # Some builds embed package-scoped install names like
                # @rpath/zlib.net/v1.3.1/lib/libz.1.3.1.dylib while LC_RPATH
                # already points at the final .../lib directory. In that case
                # the usable on-disk path is simply <rpath>/<basename>.
                candidate="$norm/$leaf"
                if [ -f "$candidate" ]; then
                    realpath "$candidate"
                    return 0
                fi
            done
            if [ -n "${HOME:-}" ]; then
                local pkgx_candidate="$HOME/.pkgx/$suffix"
                if [ -f "$pkgx_candidate" ]; then
                    realpath "$pkgx_candidate"
                    return 0
                fi
                if resolve_pkgx_leaf "$leaf"; then
                    return 0
                fi
            fi
            local opt_candidate="/opt/$suffix"
            if [ -f "$opt_candidate" ]; then
                realpath "$opt_candidate"
                return 0
            fi
            ;;
        @loader_path/*)
            local suffix="${ref#@loader_path/}"
            local candidate="$loader_dir/$suffix"
            if [ -f "$candidate" ]; then
                realpath "$candidate"
                return 0
            fi
            ;;
        @executable_path/*)
            ;;
        /*)
            if [ -f "$ref" ]; then
                realpath "$ref"
                return 0
            fi
            ;;
    esac
    return 1
}

get_deps() {
    otool -L "$1" 2>/dev/null \
        | tail -n +2 \
        | awk '{print $1}' \
        | while read -r ref; do
            is_system_lib "$ref" && continue
            echo "$ref"
        done
}

# ---------------------------------------------------------------------------
# Set up dist directory
# ---------------------------------------------------------------------------

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/lib" "$DIST_DIR/share/qemu"

echo "Copying binary..."
cp "$MAIN_BINARY" "$DIST_DIR/qemu-system-aarch64"

for tool in $REQUIRED_BINARIES; do
    src="$BUILD_DIR/$tool"
    echo "Copying tool: $tool"
    cp "$src" "$DIST_DIR/$tool"
done

if [ -d "$BUILD_DIR/pc-bios" ]; then
    echo "Copying firmware/data files..."
    SRC_BIOS="$(dirname "$BUILD_DIR")/pc-bios"
    # aarch64 firmware. We ship both the code blob and the vars
    # template; qemu needs the template to seed a per-VM NVRAM file
    # on first boot, and the launcher (qemu-vfio-apple) explodes with
    # "missing in bundle" if it isn't there. edk2-arm-vars.fd is the
    # canonical generic arm vars file — it's byte-compatible with
    # aarch64 because the vars volume is just a FAT-ish NVRAM blob.
    for f in edk2-aarch64-code.fd edk2-arm-vars.fd; do
        if [ -f "$BUILD_DIR/pc-bios/$f" ]; then
            cp "$BUILD_DIR/pc-bios/$f" "$DIST_DIR/share/qemu/"
        else
            echo "warning: missing $BUILD_DIR/pc-bios/$f" >&2
        fi
    done
    # PCI option ROMs (efi-virtio.rom etc.) — these live in source pc-bios/
    for f in "$SRC_BIOS"/efi-*.rom; do
        cp "$f" "$DIST_DIR/share/qemu/" 2>/dev/null || true
    done
    # Shared data
    for d in keymaps descriptors; do
        cp -R "$BUILD_DIR/pc-bios/$d" "$DIST_DIR/share/qemu/" 2>/dev/null || true
    done
fi

# ---------------------------------------------------------------------------
# Recursively collect all non-system dylibs (BFS)
# ---------------------------------------------------------------------------

get_rpaths "$MAIN_BINARY" > "$RPATHS_FILE"

echo "Resolving dependencies..."

# Seed queue with the bundled binaries' direct deps
seed_binary_deps() {
    local binary="$1"
    local binary_rpaths_file="$WORK/seed_rpaths_tmp"
    get_rpaths "$binary" > "$binary_rpaths_file"
    cat "$RPATHS_FILE" >> "$binary_rpaths_file"
    get_deps "$binary" | while read -r ref; do
        resolved=$(resolve_ref "$ref" "$(dirname "$(realpath "$binary")")" $(cat "$binary_rpaths_file")) || {
            echo "  warning: could not resolve $ref (from $(basename "$binary"))" >&2
            continue
        }
        echo "$resolved"
    done
}

seed_binary_deps "$MAIN_BINARY" > "$QUEUE_FILE"
for tool in $REQUIRED_BINARIES; do
    src="$BUILD_DIR/$tool"
    seed_binary_deps "$src" >> "$QUEUE_FILE"
done

while [ -s "$QUEUE_FILE" ]; do
    cp "$QUEUE_FILE" "$WORK/current_queue"
    > "$QUEUE_FILE"

    while read -r real; do
        is_seen "$real" && continue
        mark_seen "$real"

        bname="$(basename "$real")"
        set_libmap "$real" "$bname"
        set_origdir "$bname" "$(dirname "$real")"

        echo "  bundling $bname"
        cp "$real" "$DIST_DIR/lib/$bname"
        chmod u+w "$DIST_DIR/lib/$bname"

        # Merge this library's rpaths with the binary rpaths
        lib_rpaths_file="$WORK/lib_rpaths_tmp"
        get_rpaths "$real" > "$lib_rpaths_file"
        cat "$RPATHS_FILE" >> "$lib_rpaths_file"

        get_deps "$real" | while read -r ref; do
            dep_resolved=$(resolve_ref "$ref" "$(dirname "$real")" $(cat "$lib_rpaths_file")) || {
                echo "  warning: could not resolve $ref (from $bname)" >&2
                continue
            }
            if ! is_seen "$dep_resolved"; then
                echo "$dep_resolved"
            fi
        done >> "$QUEUE_FILE"
    done < "$WORK/current_queue"
done

lib_count=$(wc -l < "$SEEN_FILE" | tr -d ' ')
echo "Bundled $lib_count libraries."

# ---------------------------------------------------------------------------
# Rewrite install names
# ---------------------------------------------------------------------------

echo "Rewriting install names..."

rewrite_file() {
    local file="$1"
    local prefix="$2"         # @executable_path/lib or @loader_path
    local orig_dir="${3:-}"   # original source dir (for resolving @loader_path)

    # Collect rpaths from the ORIGINAL binary (the dist copy's rpaths are the
    # same at this point since we haven't deleted them yet)
    local rp_file="$WORK/rw_rpaths_tmp"
    get_rpaths "$file" > "$rp_file"
    cat "$RPATHS_FILE" >> "$rp_file"

    # For @loader_path resolution: use the original source directory if provided,
    # otherwise fall back to the file's current directory
    local resolve_dir="${orig_dir:-$(dirname "$(realpath "$file")")}"

    otool -L "$file" | tail -n +2 | awk '{print $1}' | while read -r ref; do
        is_system_lib "$ref" && continue

        local resolved=""
        resolved=$(resolve_ref "$ref" "$resolve_dir" $(cat "$rp_file")) || true

        if [ -n "$resolved" ]; then
            local mapped
            mapped=$(get_libmap "$resolved")
            if [ -n "$mapped" ]; then
                local new_name="$prefix/$mapped"
                if [ "$ref" != "$new_name" ]; then
                    install_name_tool -change "$ref" "$new_name" "$file" 2>/dev/null || true
                fi
            fi
        fi
    done

    # Rewrite LC_ID_DYLIB
    case "$file" in
        *.dylib)
            local self_id
            self_id=$(otool -D "$file" 2>/dev/null | tail -1)
            if [ -n "$self_id" ] && ! is_system_lib "$self_id"; then
                install_name_tool -id "$prefix/$(basename "$file")" "$file" 2>/dev/null || true
            fi
            ;;
    esac

    # Remove all old RPATHs
    get_rpaths "$file" | while read -r rp; do
        install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null || true
    done
}

# Rewrite bundled executables (no orig_dir needed, they use @rpath not @loader_path)
rewrite_file "$DIST_DIR/qemu-system-aarch64" "@executable_path/lib"
for tool in $REQUIRED_BINARIES; do
    rewrite_file "$DIST_DIR/$tool" "@executable_path/lib"
done

# Rewrite each bundled library, passing the original source directory
for dylib in "$DIST_DIR"/lib/*.dylib; do
    bname="$(basename "$dylib")"
    orig_dir=$(get_origdir "$bname")
    rewrite_file "$dylib" "@loader_path" "$orig_dir"
done

# ---------------------------------------------------------------------------
# Codesign (required on Apple Silicon)
# ---------------------------------------------------------------------------

echo "Codesigning with identity: $CODESIGN_IDENTITY"

SIGN_OPTS=(--force --sign "$CODESIGN_IDENTITY" --timestamp)
if [ "$CODESIGN_IDENTITY" = "-" ]; then
    # Ad-hoc signing: no timestamp, no hardened runtime needed
    SIGN_OPTS=(--force --sign -)
else
    # Developer ID: hardened runtime required for notarization
    SIGN_OPTS+=(--options runtime)
fi

# Sign dylibs first (dependencies before dependents)
for dylib in "$DIST_DIR"/lib/*.dylib; do
    codesign "${SIGN_OPTS[@]}" "$dylib"
done

# Sign additional tools without hypervisor entitlements
for tool in $REQUIRED_BINARIES; do
    codesign "${SIGN_OPTS[@]}" "$DIST_DIR/$tool"
done

# Sign the main binary last, with entitlements
if [ -f "$ENTITLEMENTS" ]; then
    codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$DIST_DIR/qemu-system-aarch64"
else
    codesign "${SIGN_OPTS[@]}" "$DIST_DIR/qemu-system-aarch64"
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo ""
echo "Verifying binary references:"
found_stray=0
verify_executable_refs() {
    local exe="$1"
    local name
    name="$(basename "$exe")"
    otool -L "$exe" | tail -n +2 | awk '{print $1}' > "$WORK/verify_refs_$name"
    while read -r ref; do
        is_system_lib "$ref" && continue
        case "$ref" in
            @executable_path/*)
                target="${ref#@executable_path/lib/}"
                if [ ! -f "$DIST_DIR/lib/$target" ]; then
                    echo "  BROKEN in $name: $ref (target missing)"
                    found_stray=1
                fi
                continue
                ;;
        esac
        echo "  UNBUNDLED in $name: $ref"
        found_stray=1
    done < "$WORK/verify_refs_$name"
}

verify_executable_refs "$DIST_DIR/qemu-system-aarch64"
for tool in $REQUIRED_BINARIES; do
    verify_executable_refs "$DIST_DIR/$tool"
done

# Also verify all bundled libs
for dylib in "$DIST_DIR"/lib/*.dylib; do
    bname="$(basename "$dylib")"
    otool -L "$dylib" | tail -n +2 | awk '{print $1}' | while read -r ref; do
        is_system_lib "$ref" && continue
        case "$ref" in
            @loader_path/*)
                # Check the referenced file actually exists in dist/lib/
                target="${ref#@loader_path/}"
                if [ ! -f "$DIST_DIR/lib/$target" ]; then
                    echo "  BROKEN in $bname: $ref (target missing)"
                    echo "STRAY" >> "$WORK/stray_flag"
                fi
                ;;
            *)
                echo "  UNREWRITTEN in $bname: $ref"
                echo "STRAY" >> "$WORK/stray_flag"
                ;;
        esac
    done
done

if [ -f "$WORK/stray_flag" ]; then
    found_stray=1
fi

if [ "$found_stray" -eq 0 ]; then
    echo "  All references OK (system or @executable_path/@loader_path)"
fi

# ---------------------------------------------------------------------------
# Notarize (optional, requires Developer ID signing)
# ---------------------------------------------------------------------------

if [ "${NOTARIZE:-}" = "1" ] && [ "$CODESIGN_IDENTITY" != "-" ]; then
    APPLE_ID="${APPLE_ID:?Set APPLE_ID=you@example.com for notarization}"
    TEAM_ID="${TEAM_ID:?Set TEAM_ID=XXXXXXXXXX for notarization}"

    echo ""
    echo "Notarizing..."
    ZIP_FILE="$WORK/dist-notarize.zip"
    ditto -c -k --keepParent "$DIST_DIR" "$ZIP_FILE"

    xcrun notarytool submit "$ZIP_FILE" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --keychain-profile "notarytool" \
        --wait

    echo "Notarization accepted. Gatekeeper will validate online."
fi

TARBALL="$DIST_DIR.tar.gz"
echo ""
echo "Creating $TARBALL..."
tar czf "$TARBALL" -C "$(dirname "$DIST_DIR")" "$(basename "$DIST_DIR")"

echo ""
echo "Distribution created:"
echo "  dir:     $DIST_DIR/"
echo "  tarball: $TARBALL"
echo "  libs:    $lib_count dylibs"
echo "  signed:  $CODESIGN_IDENTITY"
du -sh "$DIST_DIR" "$TARBALL" | awk '{print "  " $2 ": " $1}'
