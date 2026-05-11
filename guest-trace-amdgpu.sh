#!/bin/bash
#
# Run INSIDE the guest VM (not on the host) to capture amdgpu register
# accesses via ftrace. This is the replacement for host-side BAR MMIO
# tracing, which is broken on Apple Silicon HVF (HVF cannot decode all
# trapping load/store instructions).
#
# Usage:
#   # Copy to VM first:
#   scp -P 2222 guest-trace-amdgpu.sh geramy@127.0.0.1:~/
#   # Run inside VM:
#   ssh -p 2222 geramy@127.0.0.1 'sudo ~/guest-trace-amdgpu.sh start'
#
# Subcommands:
#   start       -- Arm function tracer on amdgpu RREG32/WREG32 family
#   stop        -- Disable tracer
#   dump <out>  -- Copy current trace buffer to <out>
#   reset       -- Clear trace buffer
#   status      -- Show tracer state and buffer usage
#
# Workflow:
#   1. sudo ./guest-trace-amdgpu.sh reset    # clear any old data
#   2. sudo ./guest-trace-amdgpu.sh start    # arm
#   3. <trigger the GPU init / llama-cli / whatever you want to capture>
#   4. sudo ./guest-trace-amdgpu.sh stop     # disable so buffer stops filling
#   5. sudo ./guest-trace-amdgpu.sh dump /tmp/amdgpu-trace.txt
#   6. scp the dump back to host

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (sudo)" >&2
  exit 1
fi

TRACEFS=/sys/kernel/tracing
if [ ! -d "$TRACEFS" ]; then
  TRACEFS=/sys/kernel/debug/tracing
fi
if [ ! -d "$TRACEFS" ]; then
  echo "tracefs not mounted; try: mount -t tracefs nodev /sys/kernel/tracing" >&2
  exit 1
fi

cmd="${1:-status}"

case "$cmd" in
  start)
    echo "==> arming ftrace on amdgpu register access functions"
    echo nop > "$TRACEFS/current_tracer"
    echo > "$TRACEFS/set_ftrace_filter"
    # Add all the register-access entry points amdgpu uses. Wildcards work.
    for sym in \
        'amdgpu_device_rreg' 'amdgpu_device_wreg' \
        'amdgpu_mm_rreg*' 'amdgpu_mm_wreg*' \
        'amdgpu_kiq_rreg*' 'amdgpu_kiq_wreg*' \
        'psp_*' 'smu_v14_0_*' 'smu_cmn_*' \
        'amdgpu_ucode_*' ; do
      echo "$sym" >> "$TRACEFS/set_ftrace_filter" 2>/dev/null || true
    done
    echo 4096 > "$TRACEFS/buffer_size_kb"   # 4MB ring buffer per CPU
    echo function > "$TRACEFS/current_tracer"
    echo 1 > "$TRACEFS/tracing_on"
    echo "    tracer:  $(cat $TRACEFS/current_tracer)"
    echo "    filters: $(wc -l < $TRACEFS/set_ftrace_filter) symbols armed"
    echo "    buffer:  $(cat $TRACEFS/buffer_size_kb) KB/cpu"
    ;;

  stop)
    echo 0 > "$TRACEFS/tracing_on"
    echo "==> tracing stopped"
    ;;

  reset)
    echo 0 > "$TRACEFS/tracing_on"
    echo nop > "$TRACEFS/current_tracer"
    echo > "$TRACEFS/trace"
    echo "==> buffer cleared, tracer set to nop"
    ;;

  dump)
    out="${2:-/tmp/amdgpu-trace.txt}"
    echo 0 > "$TRACEFS/tracing_on"
    cp "$TRACEFS/trace" "$out"
    chmod 0644 "$out"
    chown "$(logname 2>/dev/null || echo root):$(logname 2>/dev/null || echo root)" "$out" 2>/dev/null || true
    lines=$(wc -l < "$out")
    bytes=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")
    echo "==> wrote $out ($lines lines, $bytes bytes)"
    echo "    To copy back to host:"
    echo "    scp -P 2222 geramy@127.0.0.1:$out ./traces/"
    ;;

  status)
    echo "tracefs:         $TRACEFS"
    echo "current_tracer:  $(cat $TRACEFS/current_tracer)"
    echo "tracing_on:      $(cat $TRACEFS/tracing_on)"
    echo "buffer_size_kb:  $(cat $TRACEFS/buffer_size_kb) KB/cpu"
    if [ -f "$TRACEFS/set_ftrace_filter" ]; then
      n=$(wc -l < "$TRACEFS/set_ftrace_filter")
      echo "filters armed:   $n symbols"
    fi
    echo "trace events:    ~$(wc -l < $TRACEFS/trace) lines in buffer"
    ;;

  *)
    echo "usage: $0 {start|stop|reset|dump [file]|status}" >&2
    exit 1
    ;;
esac
