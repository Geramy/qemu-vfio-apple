#!/usr/bin/env python3
"""
Toggle QEMU trace events at runtime via QMP.

Requires the VM to be running in debug or trace mode (launch.sh debug|trace),
which opens a QMP UNIX socket at ./qmp.sock.

Usage:
  ./trace-control.sh list                    # show enabled events
  ./trace-control.sh status [<glob>]         # show all events (optionally filtered)
  ./trace-control.sh on  <glob>              # enable events matching glob
  ./trace-control.sh off <glob>              # disable events matching glob
  ./trace-control.sh save <file>             # save snapshot of current trace bin
  ./trace-control.sh stop                    # disable all events (quick mute)

Examples:
  ./trace-control.sh on  'apple_dma_*'       # capture only apple-dma path
  ./trace-control.sh on  'vfio_iommu_*'      # add VFIO IOMMU events
  ./trace-control.sh off '*'                 # disable everything
"""

import json
import os
import socket
import sys

SOCK_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "qmp.sock")


class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.connect(path)
        except (FileNotFoundError, ConnectionRefusedError) as e:
            sys.exit(f"error: cannot connect to {path}: {e}\n"
                     f"hint: launch the VM with `./launch.sh debug` or `trace` first.")
        self.f = self.sock.makefile("rwb", buffering=0)
        # Read banner.
        self._readline()
        # Negotiate capabilities.
        self.cmd("qmp_capabilities")

    def _readline(self):
        line = self.f.readline()
        if not line:
            sys.exit("error: QMP socket closed unexpectedly")
        return json.loads(line)

    def cmd(self, _cmd, **args):
        req = {"execute": _cmd}
        if args:
            req["arguments"] = args
        self.f.write((json.dumps(req) + "\n").encode())
        # Skip async events; return the first reply with "return" or "error".
        while True:
            msg = self._readline()
            if "return" in msg or "error" in msg:
                if "error" in msg:
                    sys.exit(f"QMP error: {msg['error']}")
                return msg["return"]


def list_events(qmp, glob="*"):
    """Query QEMU for events matching a glob pattern (server-side filter)."""
    return qmp.cmd("trace-event-get-state", name=glob)


def show(events, header):
    if not events:
        print(f"(no events match)")
        return
    width = max(len(e["name"]) for e in events)
    print(f"{header}: {len(events)} event(s)")
    for e in sorted(events, key=lambda x: x["name"]):
        state = e["state"]
        flag = "ON " if state == "enabled" else "off"
        print(f"  [{flag}] {e['name']:<{width}}")


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    action = sys.argv[1]
    qmp = QMP(SOCK_PATH)

    if action == "list":
        events = [e for e in list_events(qmp, "*") if e["state"] == "enabled"]
        show(events, "enabled events")

    elif action == "status":
        glob = sys.argv[2] if len(sys.argv) > 2 else "*"
        events = list_events(qmp, glob)
        show(events, f"events matching {glob!r}")

    elif action == "on":
        if len(sys.argv) < 3:
            sys.exit("usage: trace-control.sh on <glob>")
        glob = sys.argv[2]
        # Server-side glob: a single set-state with the pattern toggles all
        # matching events. Verify what was actually enabled afterward.
        qmp.cmd("trace-event-set-state", name=glob, enable=True)
        matches = list_events(qmp, glob)
        enabled = [e for e in matches if e["state"] == "enabled"]
        if not matches:
            sys.exit(f"no events match glob {glob!r}")
        print(f"enabled {len(enabled)}/{len(matches)} event(s) matching {glob!r}:")
        for e in enabled:
            print(f"  + {e['name']}")

    elif action == "off":
        if len(sys.argv) < 3:
            sys.exit("usage: trace-control.sh off <glob>")
        glob = sys.argv[2]
        qmp.cmd("trace-event-set-state", name=glob, enable=False)
        matches = list_events(qmp, glob)
        if not matches:
            sys.exit(f"no events match glob {glob!r}")
        print(f"disabled {len(matches)} event(s) matching {glob!r}")

    elif action == "stop":
        # Disable everything via the global glob.
        before = len([e for e in list_events(qmp, "*") if e["state"] == "enabled"])
        qmp.cmd("trace-event-set-state", name="*", enable=False)
        print(f"disabled all {before} previously-enabled event(s)")

    else:
        sys.exit(f"unknown action {action!r}; try --help")


if __name__ == "__main__":
    main()
