#!/usr/bin/env bash
#
# Convert a QEMU simple-backend binary trace to text suitable for TraceCompass.
#
# Usage:
#   ./trace-to-text.sh trace-<pid>                # writes trace-<pid>.txt
#   ./trace-to-text.sh trace-<pid> out.txt        # writes to out.txt
#   ./trace-to-text.sh --latest                   # newest trace-*.bin in cwd
#
# Output format (one event per line):
#   <timestamp_ns> <pid> <event_name> <args...>
#
# TraceCompass custom-text parser regex for this output:
#   ^(?<TIMESTAMP>\d+\.\d+)\s+(?<TID>\d+)\s+(?<EventName>\w+)\s+(?<Args>.*)$
# Timestamp format: ssss.nnnnnnnnn (seconds with nanosecond fraction).

set -euo pipefail

cd "$(dirname "$0")"

SIMPLETRACE="./scripts/simpletrace.py"
TRACE_EVENTS="./trace-events-all"

# Newer QEMU consolidates trace-events into build/trace-events-all
if [ ! -f "$TRACE_EVENTS" ]; then
  if [ -f "./build/trace/trace-events-all" ]; then
    TRACE_EVENTS="./build/trace/trace-events-all"
  elif [ -f "./build/trace-events-all" ]; then
    TRACE_EVENTS="./build/trace-events-all"
  else
    echo "ERROR: cannot find trace-events-all (looked in . and ./build/)" >&2
    exit 1
  fi
fi

if [ ! -f "$SIMPLETRACE" ]; then
  echo "ERROR: $SIMPLETRACE not found" >&2
  exit 1
fi

# --latest: pick the newest binary trace in ./traces/
if [ "${1:-}" = "--latest" ]; then
  INPUT=$(ls -t traces/run-*-[0-9]* 2>/dev/null | grep -v '\.txt$' | head -1 || true)
  if [ -z "$INPUT" ]; then
    # Fallback: also look for old ./trace-<pid> layout
    INPUT=$(ls -t trace-* 2>/dev/null | grep -v '\.txt$\|\.sh$\|\.list$\|^trace-events$' | head -1 || true)
  fi
  if [ -z "$INPUT" ]; then
    echo "ERROR: no trace files in ./traces/ or cwd" >&2
    exit 1
  fi
  OUTPUT="${INPUT}.txt"
  echo "Latest trace: $INPUT -> $OUTPUT"
elif [ -n "${1:-}" ]; then
  INPUT="$1"
  OUTPUT="${2:-${INPUT}.txt}"
else
  echo "Usage: $0 <trace-file> [output.txt] | --latest" >&2
  exit 1
fi

if [ ! -f "$INPUT" ]; then
  echo "ERROR: input file $INPUT not found" >&2
  exit 1
fi

echo "Converting $INPUT using $TRACE_EVENTS ..."
python3 "$SIMPLETRACE" "$TRACE_EVENTS" "$INPUT" > "$OUTPUT"

LINES=$(wc -l < "$OUTPUT" | tr -d ' ')
SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "Wrote $OUTPUT ($LINES events, $SIZE)"
echo ""
echo "To open in TraceCompass:"
echo "  1. File -> Open Trace..., select $OUTPUT"
echo "  2. Trace Type -> Custom -> Custom Text Trace"
echo "     If you haven't defined a parser yet, use this regex:"
echo "       ^(?<TIMESTAMP>\\d+\\.\\d+)\\s+(?<TID>\\d+)\\s+(?<EventName>\\w+)\\s+(?<Args>.*)\$"
echo "     Timestamp format: ssss.nnnnnnnnn"
