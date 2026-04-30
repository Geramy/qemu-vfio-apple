#!/usr/bin/env bash
#
# patch-running-vm.sh — apply the FEX Steam-splash patch to an
# already-booted VM over SSH, without rebuilding the image.
#
# Does two things in one elevated shell session:
#   1. apt-get install -y zenity xdotool  (runtime deps for the splash
#      dialog + Steam-window detection)
#   2. injects the splash block into /usr/lib/steam/bin_steam.sh,
#      prepended above the existing 'ARCH=$(arch)' marker that
#      provision-desktop.sh's FEX re-exec patch left behind.
#
# Idempotent: re-running is safe. The splash-injection step checks for
# the STEAM_FEX_SPLASH sentinel and short-circuits if already present.
#
# Both steps run under a single `sudo bash`, so you are prompted for
# your sudo password at most once.
#
# Assumes the VM was previously provisioned by provision-desktop.sh
# (i.e. /usr/lib/steam/bin_steam.sh already has the FEX re-exec patch).
# If not, rebuild the image or run the full provisioner first.
#
# Usage:
#   ./patch-running-vm.sh <user>@<host> [ssh_port]
#
# Examples:
#   ./patch-running-vm.sh ubuntu@192.168.64.5
#   ./patch-running-vm.sh ubuntu@127.0.0.1 2233

set -euo pipefail

TARGET="${1:-}"
PORT="${2:-22}"

if [ -z "$TARGET" ]; then
    echo "usage: $0 <user>@<host> [ssh_port]" >&2
    exit 2
fi

# Build the remote work script locally. It combines the apt install
# and the Python patcher so one `sudo bash` covers both — at most one
# password prompt per run.
REMOTE_SCRIPT="$(cat <<'REMOTE_SH'
#!/bin/bash
set -euo pipefail

echo "[1/2] installing zenity + xdotool ..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y zenity xdotool

echo "[2/2] injecting splash block into /usr/lib/steam/bin_steam.sh ..."
python3 - <<'REMOTE_PY'
import re
import sys
from pathlib import Path

BIN_STEAM = Path("/usr/lib/steam/bin_steam.sh")
if not BIN_STEAM.exists():
    sys.exit("error: /usr/lib/steam/bin_steam.sh missing; is Steam installed?")

text = BIN_STEAM.read_text()

MARKER = "ARCH=$(arch)\n"
if MARKER not in text:
    sys.exit(
        "error: marker 'ARCH=$(arch)' not found in bin_steam.sh.\n"
        "This script assumes the FEX re-exec patch was already applied\n"
        "by provision-desktop.sh. Rebuild the image or run the full\n"
        "provisioner first."
    )

# If an older splash block is already installed (live-patched from a prior
# run of this script), strip it so we can reinject the current version.
# The block always starts with the "# FEX splash (aarch64/FEX only):"
# comment and ends just before the `ARCH=$(arch)` marker. Match lazily so
# we strip exactly one block even if someone stacked them.
splash_already_current = False
if "STEAM_FEX_SPLASH" in text:
    stripped, n = re.subn(
        r"# FEX splash \(aarch64/FEX only\):.*?\nfi\n\n(?=ARCH=\$\(arch\)\n)",
        "",
        text,
        count=1,
        flags=re.DOTALL,
    )
    if n == 0:
        # Sentinel present but no recognizable block — bail out rather
        # than double-inject and create a subtly broken script.
        sys.exit(
            "error: STEAM_FEX_SPLASH found in bin_steam.sh but splash\n"
            "block could not be located for replacement. Inspect\n"
            "/usr/lib/steam/bin_steam.sh by hand."
        )
    # "__steam_main_up" is the new-version signature; if it's already there,
    # the installed block matches what we'd write, so no rewrite needed.
    if "__steam_main_up" in text:
        splash_already_current = True
    else:
        print("stripping previously installed splash block before reinjecting")
        text = stripped

# NOTE: this block is duplicated from provision-desktop.sh's
# patch_steam_bin_for_arm64() function. Keep both in sync if the
# splash UX changes. Fresh image builds run the provisioner's copy;
# this script exists only for patching already-booted VMs without
# a rebuild.
SPLASH = (
    "# FEX splash (aarch64/FEX only): show a GTK dialog while FEX\n"
    "# JIT-translates the Steam bootstrap + steamwebhelper. Dismisses\n"
    "# when any Steam window appears (polled via xdotool -- Steam runs\n"
    "# under XWayland even on GNOME/Wayland) or after zenity's 3min\n"
    "# timeout, whichever fires first. Runs on native arm64 so the\n"
    "# dialog pops up instantly; the backgrounded subshell survives\n"
    "# the FEXBash re-exec below. STEAM_FEX_SPLASH_ACTIVE keeps the\n"
    "# x86 re-entry from spawning a second dialog on top of the first.\n"
    "# Disable entirely with STEAM_FEX_SPLASH=0.\n"
    "if [ \"${STEAM_FEX_SPLASH:-1}\" = \"1\" ] \\\n"
    "        && [ -z \"${STEAM_FEX_SPLASH_ACTIVE:-}\" ] \\\n"
    "        && [ -n \"${DISPLAY:-}${WAYLAND_DISPLAY:-}\" ] \\\n"
    "        && command -v zenity >/dev/null 2>&1; then\n"
    "    # Second-launch guard: if Steam is already running, this\n"
    "    # invocation just refocuses the existing window. Showing +\n"
    "    # auto-dismissing the splash would cause a ~1s flicker.\n"
    "    # Use the same size-gated detection as the dismissal loop\n"
    "    # below so transient bootstrap windows are not misread as\n"
    "    # an already-running main UI.\n"
    "    __steam_main_up() {\n"
    "        command -v xdotool >/dev/null 2>&1 || return 1\n"
    "        local wid geom\n"
    "        for wid in $(xdotool search --onlyvisible --class Steam 2>/dev/null); do\n"
    "            geom=$(xdotool getwindowgeometry --shell \"$wid\" 2>/dev/null) || continue\n"
    "            eval \"$geom\"\n"
    "            if [ \"${WIDTH:-0}\" -ge 500 ] && [ \"${HEIGHT:-0}\" -ge 400 ]; then\n"
    "                return 0\n"
    "            fi\n"
    "        done\n"
    "        return 1\n"
    "    }\n"
    "    if __steam_main_up; then\n"
    "        :\n"
    "    else\n"
    "        export STEAM_FEX_SPLASH_ACTIVE=1\n"
    "        (\n"
    "            zenity --info --title=\"Steam\" --no-wrap --width=420 --timeout=180 \\\n"
    "                --text=$'<b>Starting Steam...</b>\\n\\nFirst launch after boot warms FEX\\'s x86 translation\\ncache and can take up to a minute. Subsequent\\nlaunches are much faster.' \\\n"
    "                >/dev/null 2>&1 &\n"
    "            splash_pid=$!\n"
    "            # Wait for Steam's main library UI, identified by a\n"
    "            # minimum window size -- Steam opens a few small\n"
    "            # bootstrap / updater / sign-in dialogs first that\n"
    "            # also carry WM_CLASS=Steam but are not the main UI.\n"
    "            while kill -0 \"$splash_pid\" 2>/dev/null; do\n"
    "                if __steam_main_up; then\n"
    "                    break\n"
    "                fi\n"
    "                sleep 1\n"
    "            done\n"
    "            kill \"$splash_pid\" 2>/dev/null || true\n"
    "        ) >/dev/null 2>&1 &\n"
    "        disown 2>/dev/null || true\n"
    "    fi\n"
    "fi\n"
    "\n"
)

if splash_already_current:
    print("splash already up to date; nothing to do")
else:
    BIN_STEAM.write_text(text.replace(MARKER, SPLASH + MARKER, 1))
    print("bin_steam.sh patched with splash block")
REMOTE_PY
REMOTE_SH
)"

# base64-encode the script so we can deliver it as a single argument
# to the remote shell. Piping via stdin would collide with sudo's
# password prompt on the pty; embedding the payload keeps stdin free
# for interactive auth.
ENCODED="$(printf '%s' "$REMOTE_SCRIPT" | base64)"

# -t allocates a pty so sudo can prompt for the password on /dev/tty
# (sudo reads the password from /dev/tty, not stdin, so the pipeline
# feeding the decoded script into sudo bash does not interfere).
echo "connecting to $TARGET ..."
ssh -t -p "$PORT" -o LogLevel=ERROR "$TARGET" \
    "printf '%s' '$ENCODED' | base64 -d | sudo bash"

echo
echo "Done. Quit Steam if it is running, then relaunch it to see the splash."
echo "Disable at any time with: STEAM_FEX_SPLASH=0 steam"
