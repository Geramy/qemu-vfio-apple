#!/usr/bin/env bash
#
# Runs inside the guest (via ssh from seal-image.sh) to turn the edited
# VM disk back into a reusable golden image:
#
#   - wipe machine-specific identifiers (ssh host keys, machine-id,
#     DHCP/NM leases, cloud-init state) so every fresh clone comes up
#     distinct
#   - drop caches that bloat the qcow2 without adding value
#     (apt lists / archives, journald, user caches, bash_history, ...)
#   - fstrim so the host-side `qemu-img convert -c` can actually drop
#     the freed blocks during recompaction
#
# Steam/FEX/GNOME user state (game library, Steam login, desktop-icon
# trust, dconf tweaks) is *kept* — that's the whole point of the
# edit/seal loop. If you want a strictly anonymous snapshot, delete
# `~/.local/share/Steam` and re-run. We intentionally do not make
# that decision on your behalf.
#
# Must be idempotent: running twice should do no harm.

set -euo pipefail

log() { printf '[seal-desktop] %s\n' "$*"; }

# -----------------------------------------------------------------
# Identity / first-boot state
# -----------------------------------------------------------------

log "resetting ssh host keys"
sudo rm -f /etc/ssh/ssh_host_*
# The provisioning pipeline installs /etc/systemd/system/qemu-vfio-firstboot.service
# whose ExecStart runs `ssh-keygen -A` if keys are missing and is ordered
# Before=ssh.service. It's gated by
#   ConditionPathExists=!/var/lib/qemu-vfio/first-boot-complete
# to make it a genuine *first*-boot-only step, so we also have to delete
# the marker here — otherwise the unit short-circuits on deployment,
# ssh.service starts without host keys, and sshd's ExecStartPre=-t fails.
sudo rm -f /var/lib/qemu-vfio/first-boot-complete

log "truncating /etc/machine-id"
# Trick documented in systemd(1) and cloud-image docs: leave the file
# empty (not missing) so systemd regenerates on next boot and dbus's
# /var/lib/dbus/machine-id (which is typically a symlink on Ubuntu)
# picks up the new value automatically.
sudo truncate -s 0 /etc/machine-id
if [ -e /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ]; then
    sudo rm -f /var/lib/dbus/machine-id
    sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
fi

log "clearing cloud-init state"
sudo cloud-init clean --logs --seed || true
sudo rm -rf /var/lib/cloud/instances/* /var/lib/cloud/data/* /var/lib/cloud/seed/nocloud-net

log "clearing DHCP / NetworkManager leases"
sudo rm -rf /var/lib/dhcp/* /var/lib/dhcpcd/* \
    /var/lib/NetworkManager/*.lease \
    /var/lib/NetworkManager/*.leases \
    /var/lib/NetworkManager/seen-bssids \
    /var/lib/NetworkManager/timestamps \
    /var/lib/systemd/network/*.lease \
    /var/lib/systemd/network/*.leases || true

log "clearing systemd random seed / credentials"
sudo rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret

# -----------------------------------------------------------------
# Logs / caches
# -----------------------------------------------------------------

log "rotating + vacuuming journal"
sudo journalctl --rotate
sudo journalctl --vacuum-time=1s

log "cleaning apt"
sudo apt-get -y autoremove --purge
sudo apt-get -y clean
sudo rm -rf /var/lib/apt/lists/*
sudo rm -rf /var/cache/apt/archives/partial/*
sudo find /var/cache/apt/archives -maxdepth 1 -name '*.deb' -delete

log "clearing per-user caches / history"
sudo rm -rf /tmp/* /var/tmp/* || true
# Every home dir on the machine, not just the invoking user.
#
# Do NOT delete ~/.local/share/gvfs-metadata — GNOME stores the
# metadata::trusted bit that right-click "Allow launching" sets on
# desktop icons (Steam, etc.) there, and wiping it un-trusts every
# icon on every fresh boot of the sealed image. It's tiny, per-user,
# and machine-id-independent, so it's safe to keep.
#
# Inside ~/.cache we wipe everything *except* fex-emu/ — that's
# FEX-Emu's AOT / IR / object code cache for every x86 ELF it has
# JIT-translated. Without it, the first cold launch of Steam on any
# fresh clone re-JITs the whole bootstrap + steamwebhelper chain
# (~60s with no UI indication it's even happening). Preserving it
# turns subsequent cold launches into ~10-15s. FEX keys the cache on
# ELF checksums, so it's safe to share across clones (not
# machine-identity-bound).
for home in /root /home/*; do
    [ -d "$home" ] || continue
    sudo rm -rf \
        "$home/.bash_history" \
        "$home/.zsh_history" \
        "$home/.viminfo" \
        "$home/.sudo_as_admin_successful" \
        "$home/.wget-hsts" \
        "$home/.lesshst" \
        "$home/.local/share/recently-used.xbel" \
        || true
    if [ -d "$home/.cache" ]; then
        sudo find "$home/.cache" -mindepth 1 -maxdepth 1 \
            ! -name fex-emu \
            -exec rm -rf {} +
    fi
done

# -----------------------------------------------------------------
# Filesystem trim
# -----------------------------------------------------------------

log "fstrim (frees blocks the hypervisor can discard)"
sudo fstrim -av || true

log "sealing complete; powering off"
# Fire-and-forget — the parent ssh session will get disconnected by
# the poweroff halfway through. Using `nohup … &` keeps systemd from
# SIGKILL'ing the spawning shell before it issues shutdown.
nohup sudo systemctl poweroff >/dev/null 2>&1 &
exit 0
