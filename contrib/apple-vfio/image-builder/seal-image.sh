#!/usr/bin/env bash
#
# Take the scratch qcow2 left behind by edit-image.sh, re-seal it as
# a golden image (wipe machine-specific state + fstrim), recompact
# it, and replace the release artifact + manifest in-place.
#
# High-level flow:
#   1. Boot the scratch disk headless with ssh hostfwd on 127.0.0.1.
#   2. Wait for ssh to come up (guest cold boot is slow on aarch64/hvf).
#   3. scp guest/seal-desktop.sh into the guest over ssh (driven by
#      `expect`, so we don't need sshpass).
#   4. Run it — it wipes machine-id, host keys, caches, etc., then
#      fires `systemctl poweroff`.
#   5. Wait for the qemu process to exit.
#   6. `qemu-img convert -c -O qcow2` the (now clean) scratch into the
#      final artifact. Recompress so the sealed image ships small.
#   7. Update `<name>.manifest.json` with the new sha256 + size so the
#      publish step has fresh metadata.
#
# Usage:
#   ./contrib/apple-vfio/image-builder/seal-image.sh [output-dir]
#
# Environment (all optional, mirror build-ubuntu-desktop-image.sh):
#   IMAGE_NAME, CPUS, MEMORY, BUILD_USER, BUILD_PASSWORD,
#   EDIT_SSH_PORT, QEMU_BIN, QEMU_IMG_BIN, QEMU_DATA_DIR,
#   EFI_CODE_SRC, EFI_VARS_SRC, SEAL_TIMEOUT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

OUT_DIR="${1:-$REPO_ROOT/contrib/apple-vfio/image-builder/out/ubuntu-desktop-image}"
WORK_DIR="$OUT_DIR/work"
ARTIFACT_DIR="$OUT_DIR/artifacts"

IMAGE_NAME="${IMAGE_NAME:-ubuntu-desktop-resolute-arm64}"
CPUS="${CPUS:-8}"
MEMORY="${MEMORY:-12G}"
BUILD_USER="${BUILD_USER:-ubuntu}"
BUILD_PASSWORD="${BUILD_PASSWORD:-ubuntu}"
EDIT_SSH_PORT="${EDIT_SSH_PORT:-2233}"
SEAL_TIMEOUT="${SEAL_TIMEOUT:-600}"

FINAL_IMAGE="$ARTIFACT_DIR/${IMAGE_NAME}.qcow2"
MANIFEST_PATH="$ARTIFACT_DIR/${IMAGE_NAME}.manifest.json"
EDIT_IMAGE="$WORK_DIR/${IMAGE_NAME}.edit.qcow2"
EDIT_EFI_VARS="$WORK_DIR/${IMAGE_NAME}.edit-vars.fd"
SEAL_LOG="$WORK_DIR/${IMAGE_NAME}.seal.log"
SEAL_PIDFILE="$WORK_DIR/${IMAGE_NAME}.seal.pid"
SEAL_SCRIPT="$SCRIPT_DIR/guest/seal-desktop.sh"

QEMU_BIN="${QEMU_BIN:-}"
QEMU_IMG_BIN="${QEMU_IMG_BIN:-}"
QEMU_DATA_DIR="${QEMU_DATA_DIR:-}"
EFI_CODE_SRC="${EFI_CODE_SRC:-}"
EFI_VARS_SRC="${EFI_VARS_SRC:-}"

log() { printf '[seal-image] %s\n' "$*"; }
die() { printf '[seal-image] error: %s\n' "$*" >&2; exit 1; }

pick_existing() {
    local c
    for c in "$@"; do
        if [ -n "$c" ] && [ -e "$c" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

resolve_qemu() {
    if [ -z "$QEMU_BIN" ]; then
        QEMU_BIN="$(pick_existing \
            "$REPO_ROOT/dist/qemu-system-aarch64" \
            "$REPO_ROOT/build/qemu-system-aarch64" \
        )" || die "qemu-system-aarch64 not found"
    fi
    if [ -z "$QEMU_IMG_BIN" ]; then
        QEMU_IMG_BIN="$(pick_existing \
            "$REPO_ROOT/dist/qemu-img" \
            "$REPO_ROOT/build/qemu-img" \
        )" || die "qemu-img not found"
    fi
    if [ -z "$QEMU_DATA_DIR" ]; then
        QEMU_DATA_DIR="$(pick_existing \
            "$REPO_ROOT/dist/share/qemu" \
            "$REPO_ROOT/build/qemu-bundle/usr/local/share/qemu" \
            "$REPO_ROOT/build/pc-bios" \
        )" || die "QEMU data dir not found"
    fi
    if [ -z "$EFI_CODE_SRC" ]; then
        EFI_CODE_SRC="$(pick_existing \
            "$REPO_ROOT/build/pc-bios/edk2-aarch64-code.fd" \
            "$REPO_ROOT/build/qemu-bundle/usr/local/share/qemu/edk2-aarch64-code.fd" \
            "$REPO_ROOT/dist/share/qemu/edk2-aarch64-code.fd" \
        )" || die "edk2-aarch64-code.fd not found"
    fi
    if [ -z "$EFI_VARS_SRC" ]; then
        EFI_VARS_SRC="$(pick_existing \
            "$REPO_ROOT/build/pc-bios/edk2-arm-vars.fd" \
            "$REPO_ROOT/build/pc-bios/edk2-aarch64-vars.fd" \
            "$REPO_ROOT/build/qemu-bundle/usr/local/share/qemu/edk2-arm-vars.fd" \
            "$REPO_ROOT/build/qemu-bundle/usr/local/share/qemu/edk2-aarch64-vars.fd" \
            "$REPO_ROOT/dist/share/qemu/edk2-arm-vars.fd" \
            "$REPO_ROOT/dist/share/qemu/edk2-aarch64-vars.fd" \
        )" || die "arm64 edk2 vars not found"
    fi
}

check_inputs() {
    command -v expect >/dev/null 2>&1 || die "expect(1) required (brew install expect)"
    command -v python3 >/dev/null 2>&1 || die "python3 required"
    [ -f "$EDIT_IMAGE" ] || die "no scratch disk at $EDIT_IMAGE — run edit-image.sh first"
    [ -f "$SEAL_SCRIPT" ] || die "seal script missing: $SEAL_SCRIPT"
    [ -f "$EDIT_EFI_VARS" ] || cp -f "$EFI_VARS_SRC" "$EDIT_EFI_VARS"
}

boot_seal_vm() {
    log "booting sealing VM headless (ssh: 127.0.0.1:$EDIT_SSH_PORT)"
    rm -f "$SEAL_PIDFILE" "$SEAL_LOG"
    # -display none keeps qemu entirely background-friendly. We keep
    # a serial console redirected to the log file so we can debug if
    # the guest panics instead of powering off cleanly.
    "$QEMU_BIN" \
        -L "$QEMU_DATA_DIR" \
        -accel hvf \
        -cpu host \
        -machine virt,highmem=on \
        -smp "$CPUS" \
        -m "$MEMORY" \
        -display none \
        -serial "file:$SEAL_LOG" \
        -pidfile "$SEAL_PIDFILE" \
        -device virtio-rng-pci \
        -drive if=pflash,format=raw,readonly=on,file="$EFI_CODE_SRC" \
        -drive if=pflash,format=raw,file="$EDIT_EFI_VARS" \
        -drive if=virtio,format=qcow2,file="$EDIT_IMAGE",discard=unmap,detect-zeroes=unmap \
        -netdev user,id=net0,hostfwd=tcp::"$EDIT_SSH_PORT"-:22 \
        -device virtio-net-pci,netdev=net0 \
        -daemonize
}

wait_for_ssh() {
    log "waiting for sshd (up to ${SEAL_TIMEOUT}s)"
    local deadline=$(( $(date +%s) + SEAL_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        # nc -G is macOS's connect-timeout; -w is the post-connect idle
        # timeout. We want both short so failed attempts don't block
        # the poll loop for seconds at a time during boot.
        # We also require an SSH banner so we don't race sshd's
        # listening-vs-ready gap.
        if banner=$(nc -G 1 -w 1 127.0.0.1 "$EDIT_SSH_PORT" </dev/null 2>/dev/null \
                    | head -c 32); then
            case "$banner" in
                SSH-*) log "sshd up: ${banner%$'\r'}"; return 0 ;;
            esac
        fi
        sleep 2
    done
    die "timed out waiting for sshd on port $EDIT_SSH_PORT"
}

run_seal_over_ssh() {
    log "uploading + running seal-desktop.sh in guest"

    # We drive password auth via expect so the repo stays sshpass-free
    # (sshpass isn't in macOS's stock CLI and requires a custom tap to
    # install via Homebrew). expect ships with the OS.
    EDIT_SSH_PORT="$EDIT_SSH_PORT" \
    BUILD_USER="$BUILD_USER" \
    BUILD_PASSWORD="$BUILD_PASSWORD" \
    SEAL_SCRIPT="$SEAL_SCRIPT" \
    expect <<'EXPECT_EOF'
        set timeout 120
        set port    $env(EDIT_SSH_PORT)
        set user    $env(BUILD_USER)
        set pass    $env(BUILD_PASSWORD)
        set script  $env(SEAL_SCRIPT)
        set host    "127.0.0.1"

        # -- scp the seal script into /tmp/seal-desktop.sh ----------------
        spawn scp -P $port \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            -o PubkeyAuthentication=no \
            -o PreferredAuthentications=password \
            -o NumberOfPasswordPrompts=1 \
            $script $user@$host:/tmp/seal-desktop.sh
        expect {
            -re "assword:" { send "$pass\r"; exp_continue }
            eof            { }
            timeout        { puts "scp timed out"; exit 1 }
        }
        catch wait result
        set scp_rc [lindex $result 3]
        if { $scp_rc != 0 } { puts "scp failed ($scp_rc)"; exit 1 }

        # -- run it via sudo -------------------------------------------
        # Guest will poweroff from inside the script, so ssh will
        # disconnect ungracefully. That's fine; we tolerate any exit
        # status here and let wait_for_shutdown be the source of truth.
        spawn ssh -p $port \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            -o PubkeyAuthentication=no \
            -o PreferredAuthentications=password \
            -o NumberOfPasswordPrompts=1 \
            $user@$host \
            "chmod +x /tmp/seal-desktop.sh && sudo /tmp/seal-desktop.sh"
        expect {
            -re "assword:" { send "$pass\r"; exp_continue }
            eof            { }
            timeout        { puts "ssh exec timed out"; exit 1 }
        }
        exit 0
EXPECT_EOF
}

wait_for_shutdown() {
    log "waiting for guest poweroff"
    local pid
    [ -f "$SEAL_PIDFILE" ] || die "qemu pidfile missing: $SEAL_PIDFILE"
    pid="$(cat "$SEAL_PIDFILE")"
    [ -n "$pid" ] || die "empty qemu pidfile"

    local deadline=$(( $(date +%s) + SEAL_TIMEOUT ))
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            log "shutdown timeout; force-killing qemu pid $pid (image may be dirty)"
            kill -TERM "$pid" 2>/dev/null || true
            sleep 3
            kill -KILL "$pid" 2>/dev/null || true
            die "guest did not poweroff within ${SEAL_TIMEOUT}s"
        fi
        sleep 2
    done
    rm -f "$SEAL_PIDFILE"
    log "guest powered off cleanly"
}

recompact_into_artifact() {
    log "recompacting $EDIT_IMAGE -> $FINAL_IMAGE"
    mkdir -p "$ARTIFACT_DIR"
    local tmp="$FINAL_IMAGE.new"
    rm -f "$tmp"
    # -c = compressed qcow2; matches what the original build pipeline
    # produces so the sealed artifact is a drop-in replacement.
    "$QEMU_IMG_BIN" convert -p -O qcow2 -c "$EDIT_IMAGE" "$tmp"
    mv -f "$tmp" "$FINAL_IMAGE"
}

update_manifest() {
    [ -f "$MANIFEST_PATH" ] || {
        log "no pre-existing manifest at $MANIFEST_PATH — skipping manifest update"
        return 0
    }
    log "refreshing manifest sha256 + size_bytes"
    local sha size
    sha="$(shasum -a 256 "$FINAL_IMAGE" | awk '{print $1}')"
    size="$(stat -f '%z' "$FINAL_IMAGE")"

    MANIFEST_PATH="$MANIFEST_PATH" \
    ARTIFACT_SHA256="$sha" \
    ARTIFACT_SIZE="$size" \
    python3 - <<'PY'
from pathlib import Path
import json, os

p = Path(os.environ["MANIFEST_PATH"])
m = json.loads(p.read_text())
m["sha256"] = os.environ["ARTIFACT_SHA256"]
m["size_bytes"] = int(os.environ["ARTIFACT_SIZE"])
m["sealed"] = True
p.write_text(json.dumps(m, indent=2) + "\n")
PY
}

main() {
    resolve_qemu
    check_inputs
    boot_seal_vm
    # From here on we must always try to kill the VM if something
    # goes wrong, otherwise a stuck qemu holds the scratch disk open.
    trap 'if [ -f "$SEAL_PIDFILE" ]; then kill "$(cat "$SEAL_PIDFILE")" 2>/dev/null || true; fi' EXIT

    wait_for_ssh
    run_seal_over_ssh
    wait_for_shutdown

    trap - EXIT

    recompact_into_artifact
    update_manifest

    log "sealed artifact: $FINAL_IMAGE"
    log "manifest:        $MANIFEST_PATH"
    log "scratch disk retained at $EDIT_IMAGE for another round of edits."
    log "(delete it if you want the next edit session to re-branch from the sealed artifact.)"
}

main "$@"
