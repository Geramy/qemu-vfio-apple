#!/bin/bash
#
# Fetch the pinned QEMU dist tarball as an OCI artifact (ghcr.io by
# default) and extract it into the project's build-cache/ directory.
# Re-uses the extracted copy if the on-disk sha256 stamp matches the
# pin so repeated Xcode builds don't re-download or re-extract.
#
# Implements the OCI registry v2 pull protocol directly with curl +
# python3, so dev machines don't need oras / jq for builds. The push
# side does need oras (see scripts/publish-qemu-dist-to-ghcr.sh).
#
# Stdout on success: the absolute path of the extracted dist/ directory,
# suitable for use as QEMU_DIST_DIR by embed-qemu.sh. Diagnostics go to
# stderr so the caller can capture only the path.
#
# Resume: the partial download lives at <tarball>.part. curl -C - resumes
# from its current size on the next invocation, so an interrupted Xcode
# build picks up where it left off rather than re-downloading from zero.
#
# Usage:
#   fetch-qemu-dist.sh
#
# Environment overrides:
#   QEMU_DIST_PIN     path to the pin file (default: scripts/qemu-dist.pin
#                     next to this script)
#   QEMU_DIST_REPO    override the pinned ghcr repo (sha256 still enforced)
#   QEMU_DIST_TAG     override the pinned tag (sha256 still enforced)
#   QEMU_DIST_FORCE   set to 1 to redownload + re-extract unconditionally
#   QEMU_DIST_CACHE   override the cache directory (default:
#                     $SRCROOT/build-cache/qemu-dist when run from Xcode,
#                     <repo>/contrib/apple-vfio/build-cache/qemu-dist
#                     standalone)
#   GH_TOKEN          send as the bearer token instead of asking ghcr for
#                     an anonymous one. Only needed if the package is
#                     marked private. PAT scope: read:packages.
#
# Exit codes:
#   0  success — extracted dist/ is at the printed path
#   1  fatal — sha256 mismatch, network failure with no cache, etc.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PIN="${QEMU_DIST_PIN:-$HERE/qemu-dist.pin}"

if [ ! -f "$PIN" ]; then
    echo "fetch-qemu-dist: pin file not found: $PIN" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$PIN"

: "${QEMU_DIST_REPO:?pin file missing QEMU_DIST_REPO}"
: "${QEMU_DIST_TAG:?pin file missing QEMU_DIST_TAG}"
: "${QEMU_DIST_SHA256:?pin file missing QEMU_DIST_SHA256}"

# Split "ghcr.io/owner/name" into registry + repo path. The repo path is
# everything after the first slash, since ghcr expects it that way in the
# v2 API path and the token scope.
REGISTRY="${QEMU_DIST_REPO%%/*}"
REPO_PATH="${QEMU_DIST_REPO#*/}"

if [ -n "${QEMU_DIST_CACHE:-}" ]; then
    CACHE_DIR="$QEMU_DIST_CACHE"
elif [ -n "${SRCROOT:-}" ]; then
    CACHE_DIR="$SRCROOT/build-cache/qemu-dist"
else
    CACHE_DIR="$HERE/../build-cache/qemu-dist"
fi

DIST_DIR="$CACHE_DIR/dist"
STAMP_FILE="$CACHE_DIR/.stamp"
TARBALL="$CACHE_DIR/qemu-dist-${QEMU_DIST_TAG}.tar.gz"
PART="$TARBALL.part"
FORCE="${QEMU_DIST_FORCE:-0}"

mkdir -p "$CACHE_DIR"

# Cache hit: stamp matches pin AND extracted dist has the binaries we need.
if [ "$FORCE" != "1" ] \
    && [ -f "$STAMP_FILE" ] \
    && [ -f "$DIST_DIR/qemu-system-aarch64" ] \
    && [ -f "$DIST_DIR/qemu-img" ] \
    && [ "$(cat "$STAMP_FILE")" = "$QEMU_DIST_SHA256" ]; then
    echo "fetch-qemu-dist: using cached dist (sha256 ${QEMU_DIST_SHA256:0:12}…)" >&2
    echo "$DIST_DIR"
    exit 0
fi

# Reuse the previously-extracted tree when we can't reach the registry,
# so an offline rebuild doesn't break a previously-working setup.
fall_back_to_stale_cache() {
    if [ -f "$STAMP_FILE" ] \
        && [ -f "$DIST_DIR/qemu-system-aarch64" ] \
        && [ -f "$DIST_DIR/qemu-img" ]; then
        echo "fetch-qemu-dist: $1; reusing stale cache at $DIST_DIR" >&2
        echo "$DIST_DIR"
        exit 0
    fi
}

# 1. Bearer token. ghcr issues anonymous tokens for public packages via
# the /token endpoint — the token is then sent as Authorization: Bearer
# on every subsequent request. GH_TOKEN short-circuits this for private
# packages.
if [ -n "${GH_TOKEN:-}" ]; then
    TOKEN="$GH_TOKEN"
    echo "fetch-qemu-dist: using GH_TOKEN for $REGISTRY/$REPO_PATH" >&2
else
    echo "fetch-qemu-dist: requesting anonymous token for $REGISTRY/$REPO_PATH" >&2
    TOKEN_URL="https://${REGISTRY}/token?service=${REGISTRY}&scope=repository:${REPO_PATH}:pull"
    if ! TOKEN_JSON="$(curl --fail --silent --show-error --location \
            --connect-timeout 15 --max-time 30 \
            --retry 2 --retry-delay 2 \
            "$TOKEN_URL")"; then
        fall_back_to_stale_cache "token request failed"
        echo "fetch-qemu-dist: token request failed and no cached copy available" >&2
        exit 1
    fi
    TOKEN="$(printf '%s' "$TOKEN_JSON" | python3 -c '
import json, sys
try:
    j = json.load(sys.stdin)
    print(j.get("token") or j.get("access_token") or "")
except Exception:
    pass')"
    if [ -z "$TOKEN" ]; then
        echo "fetch-qemu-dist: no token in registry response: $TOKEN_JSON" >&2
        exit 1
    fi
fi

# 2. Manifest by tag. Accept both OCI and Docker schema 2 — ghcr serves
# whichever the publisher pushed. We don't currently handle multi-platform
# index manifests because we publish single-arch artifacts.
echo "fetch-qemu-dist: fetching manifest for $REPO_PATH:$QEMU_DIST_TAG" >&2
MANIFEST_URL="https://${REGISTRY}/v2/${REPO_PATH}/manifests/${QEMU_DIST_TAG}"
ACCEPT="application/vnd.oci.image.manifest.v1+json"
ACCEPT="$ACCEPT,application/vnd.docker.distribution.manifest.v2+json"
ACCEPT="$ACCEPT,application/vnd.oci.image.index.v1+json"

if ! MANIFEST_JSON="$(curl --fail --silent --show-error --location \
        --connect-timeout 15 --max-time 30 \
        --retry 2 --retry-delay 2 \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: $ACCEPT" \
        "$MANIFEST_URL")"; then
    fall_back_to_stale_cache "manifest fetch failed"
    echo "fetch-qemu-dist: manifest fetch failed and no cached copy available" >&2
    exit 1
fi

# 3. Pull the layer digest. Prefer a layer with a tar-ish mediaType, fall
# back to layer 0 if nothing matches. Refuse multi-platform indexes —
# we'd need to pick a platform and that's out of scope for v1.
LAYER_DIGEST="$(printf '%s' "$MANIFEST_JSON" | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if "manifests" in m and not m.get("layers"):
    sys.stderr.write("manifest is a multi-platform index; not supported\n")
    sys.exit(2)

layers = m.get("layers") or []
for l in layers:
    mt = l.get("mediaType") or ""
    if "tar" in mt:
        print(l["digest"]); sys.exit(0)
if layers:
    print(layers[0]["digest"])')"

if [ -z "$LAYER_DIGEST" ]; then
    echo "fetch-qemu-dist: failed to extract layer digest from manifest" >&2
    echo "  manifest body (first 200 chars): ${MANIFEST_JSON:0:200}" >&2
    exit 1
fi

# 4. Verify the manifest's referenced layer matches the pin. This is the
# key trust check: the registry can mutate tags, but if the manifest
# under that tag points at a different digest than we expect, we refuse
# to use it (and tell the user to bump the pin if the change is real).
EXPECTED_DIGEST="sha256:$QEMU_DIST_SHA256"
if [ "$LAYER_DIGEST" != "$EXPECTED_DIGEST" ]; then
    echo "fetch-qemu-dist: manifest layer digest does not match pin" >&2
    echo "  expected: $EXPECTED_DIGEST" >&2
    echo "  got:      $LAYER_DIGEST" >&2
    echo "  ($QEMU_DIST_TAG was likely repushed; bump scripts/qemu-dist.pin)" >&2
    exit 1
fi

# 5. Blob download to .part with resume. curl -C - reads .part's current
# size and sends Range: bytes=N- so a fresh invocation continues where
# the last one stopped. ghcr 307-redirects large blobs to a signed Azure
# Blob URL; the URL expires in ~7 minutes but a re-resume goes through
# the registry endpoint again and gets a fresh redirect, so long pauses
# between attempts are fine.
BLOB_URL="https://${REGISTRY}/v2/${REPO_PATH}/blobs/${LAYER_DIGEST}"

if [ -f "$TARBALL" ] && [ ! -f "$PART" ]; then
    echo "fetch-qemu-dist: found previously downloaded tarball, will verify" >&2
else
    echo "fetch-qemu-dist: downloading blob ${LAYER_DIGEST:0:19}… (resume supported)" >&2
    if ! curl --fail --silent --show-error --location \
            --connect-timeout 15 --max-time 1800 \
            --retry 3 --retry-delay 2 --retry-all-errors \
            -C - \
            -H "Authorization: Bearer $TOKEN" \
            -o "$PART" "$BLOB_URL"; then
        echo "fetch-qemu-dist: blob download failed (.part preserved for next-run resume)" >&2
        fall_back_to_stale_cache "blob download failed"
        exit 1
    fi
    mv "$PART" "$TARBALL"
fi

# 6. Final sha verification on the assembled tarball. Catches the
# pathological case where curl resumed against a truncated/reset .part
# and we ended up with garbage. On mismatch we wipe the .part + tarball
# so the next invocation starts fresh — a partial sha-mismatch file is
# almost always corrupt for unfixable reasons (server returned 200
# instead of 206, etc.) and re-resuming would just stitch more bad
# bytes onto bad bytes.
GOT_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$GOT_SHA" != "$QEMU_DIST_SHA256" ]; then
    echo "fetch-qemu-dist: sha256 mismatch on downloaded tarball" >&2
    echo "  expected: $QEMU_DIST_SHA256" >&2
    echo "  got:      $GOT_SHA" >&2
    rm -f "$TARBALL" "$PART"
    echo "  (cache cleared; re-run to redownload from scratch)" >&2
    exit 1
fi

# 7. Wipe and re-extract so we don't mix files from a previous version
# when the pin bumps.
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
echo "fetch-qemu-dist: extracting to $DIST_DIR" >&2
# Tarballs from contrib/apple-vfio/scripts/make-dist.sh have a top-level
# dist/ entry, so strip-components=1 lands its contents in $DIST_DIR.
tar -xzf "$TARBALL" -C "$DIST_DIR" --strip-components=1

if [ ! -f "$DIST_DIR/qemu-system-aarch64" ] || [ ! -f "$DIST_DIR/qemu-img" ]; then
    echo "fetch-qemu-dist: extracted dist looks malformed (missing qemu binaries)" >&2
    rm -rf "$DIST_DIR"
    exit 1
fi

printf '%s' "$QEMU_DIST_SHA256" > "$STAMP_FILE"
echo "fetch-qemu-dist: ready at $DIST_DIR" >&2
echo "$DIST_DIR"
