#!/usr/bin/env bash
#
# Push the QEMU dist tarball produced by
# contrib/apple-vfio/scripts/make-dist.sh to GHCR as an OCI artifact.
# The fetch-qemu-dist.sh side speaks the OCI v2 pull
# protocol with curl + python3 (no client tooling needed for builds);
# this side uses oras for the push because hand-rolling the upload-by-
# digest dance is significantly more annoying than the pull side.
#
# After running, bump scripts/qemu-dist.pin to point at the tag and
# sha256 you just published.
#
# Layout produced at the registry:
#
#   ghcr.io/scottjg/qemu-vfio-apple-dist:<tag>            (immutable per-tag)
#   ghcr.io/scottjg/qemu-vfio-apple-dist:latest           (rolling, optional)
#
# Usage:
#   ./scripts/publish-qemu-dist-to-ghcr.sh [tag] [tarball]
#
# Both arguments are optional:
#   tag        — defaults to `git describe --always --dirty --abbrev=12`
#                of the qemu source tree, so the registry tag carries
#                the source provenance for free. Override if you want a
#                custom name (e.g. `release-1.0`).
#   tarball    — defaults to ../../../dist.tar.gz relative to this
#                script (i.e. <qemu-root>/dist.tar.gz, the same tarball
#                that contrib/apple-vfio/scripts/make-dist.sh writes).
#
# Environment:
#   GH_USER            GitHub username (default: scottjg)
#   GH_TOKEN           PAT with write:packages scope. Optional — falls
#                      back to `gh auth token`. If you've never granted
#                      write:packages, run:
#                          gh auth refresh -h github.com -s write:packages,read:packages
#   GHCR_REPO          registry path (default: ghcr.io/scottjg/qemu-vfio-apple-dist)
#   QEMU_TREE          path to the qemu git tree used to derive the
#                      default tag (default: ../../.. relative to this
#                      script, i.e. the qemu repo this contrib dir
#                      lives inside)
#   SOURCE_REPO_URL    OCI annotation linking the artifact to a source repo
#                      (default: https://github.com/scottjg/qemu-vfio-apple)
#   ALSO_TAG_LATEST    set to 0 to skip the :latest tag push

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
QEMU_TREE="${QEMU_TREE:-$HERE/../../..}"

# Derive a default tag from the qemu source tree HEAD. `git describe
# --always` falls back to the abbrev sha when there's no nearby tag,
# which is fine for our purposes; `--dirty` appends `-dirty` if the
# working tree has uncommitted changes so a forker pulling that tag
# knows the artifact wasn't built from a clean commit. We deliberately
# don't refuse to publish dirty builds — they're useful while iterating
# on the apple-vfio bits — but we do surface the state in logs.
default_tag_from_git() {
    if [ ! -d "$QEMU_TREE/.git" ] && [ ! -f "$QEMU_TREE/.git" ]; then
        return 1
    fi
    git -C "$QEMU_TREE" describe --always --dirty --abbrev=12 2>/dev/null
}

TAG="${1:-}"
TARBALL="${2:-$HERE/../../../dist.tar.gz}"

if [ -z "$TAG" ]; then
    if ! TAG="$(default_tag_from_git)" || [ -z "$TAG" ]; then
        echo "usage: $0 [tag] [tarball]" >&2
        echo "  (could not derive default tag from QEMU_TREE=$QEMU_TREE — pass one explicitly)" >&2
        exit 1
    fi
fi

GH_USER="${GH_USER:-scottjg}"
GH_TOKEN="${GH_TOKEN:-}"
GHCR_REPO="${GHCR_REPO:-ghcr.io/scottjg/qemu-vfio-apple-dist}"
SOURCE_REPO_URL="${SOURCE_REPO_URL:-https://github.com/scottjg/qemu-vfio-apple}"
ALSO_TAG_LATEST="${ALSO_TAG_LATEST:-1}"

log() { printf '[publish-qemu-dist] %s\n' "$*"; }
die() { printf '[publish-qemu-dist] error: %s\n' "$*" >&2; exit 1; }

[ -f "$TARBALL" ] || die "tarball not found: $TARBALL"

GH_TOKEN_SOURCE="env"
if [ -z "$GH_TOKEN" ]; then
    GH_TOKEN="$(gh auth token 2>/dev/null || true)"
    GH_TOKEN_SOURCE="gh"
fi
[ -n "$GH_TOKEN" ] || die "GH_TOKEN is required (PAT with write:packages)"

command -v oras >/dev/null 2>&1 || die "oras not installed. brew install oras"

# Same scope check pattern as image-builder/scripts/publish-to-ghcr.sh:
# `gh auth login`'s default scopes don't include write:packages, so a
# token from `gh auth token` will fail at push time with a generic
# "permission_denied" — fail fast with a clear remediation instead.
check_token_scopes() {
    local hdr scopes normalized
    hdr="$(curl -fsS -I -H "Authorization: token $GH_TOKEN" \
            https://api.github.com/user 2>/dev/null || true)"
    scopes="$(printf '%s' "$hdr" \
              | awk -F': ' 'tolower($1)=="x-oauth-scopes" {sub(/\r$/,"",$2); print $2; exit}')"

    if [ -z "$scopes" ]; then
        log "could not read x-oauth-scopes (fine-grained PATs omit it; proceeding)"
        return 0
    fi

    normalized="$(printf '%s' "$scopes" | tr -d '[:space:]')"
    case ",$normalized," in
        *,write:packages,*) return 0 ;;
    esac

    printf '[publish-qemu-dist] error: token is missing write:packages scope\n' >&2
    printf '[publish-qemu-dist]        current scopes: %s\n' "$scopes" >&2
    if [ "$GH_TOKEN_SOURCE" = "gh" ]; then
        printf '[publish-qemu-dist]        fix: gh auth refresh -h github.com -s write:packages,read:packages\n' >&2
    else
        printf '[publish-qemu-dist]        fix: regenerate your PAT with write:packages\n' >&2
    fi
    exit 1
}
check_token_scopes

SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
SIZE="$(stat -f%z "$TARBALL" 2>/dev/null || stat -c%s "$TARBALL")"
log "tag:     $TAG"
case "$TAG" in
    *-dirty)
        log "         WARNING: source tree has uncommitted changes — artifact won't be reproducible from git" ;;
esac
log "tarball: $TARBALL"
log "  size:    $SIZE bytes"
log "  sha256:  $SHA256"

log "logging in to ghcr.io as $GH_USER"
echo "$GH_TOKEN" | oras login ghcr.io -u "$GH_USER" --password-stdin

# Stage the tarball under a deterministic name inside a temp dir so the
# OCI layer's title annotation is predictable (oras uses the file's
# basename in the working dir as the layer title).
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

LAYER_NAME="qemu-dist-${TAG}-arm64.tar.gz"
cp "$TARBALL" "$work/$LAYER_NAME"

pushd "$work" >/dev/null

artifact_type="application/vnd.scottjg.qemu-vfio.dist.v1"
layer_media="application/vnd.scottjg.qemu-vfio.dist+tar.gz"

push_for_tag() {
    local push_tag="$1"
    log "pushing $GHCR_REPO:$push_tag"
    oras push "$GHCR_REPO:$push_tag" \
        --artifact-type "$artifact_type" \
        --annotation "org.opencontainers.image.source=$SOURCE_REPO_URL" \
        --annotation "org.opencontainers.image.title=qemu-dist-$TAG" \
        --annotation "org.opencontainers.image.description=apple-vfio QEMU dist tarball (qemu-system-aarch64 + qemu-img + dylibs + share)" \
        --annotation "org.opencontainers.image.licenses=GPL-2.0" \
        "$LAYER_NAME:$layer_media"
}

push_for_tag "$TAG"
if [ "$ALSO_TAG_LATEST" = "1" ]; then
    push_for_tag "latest"
fi

popd >/dev/null

log "done. update scripts/qemu-dist.pin to:"
log "  QEMU_DIST_REPO=$GHCR_REPO"
log "  QEMU_DIST_TAG=$TAG"
log "  QEMU_DIST_SHA256=$SHA256"
