/*
 * Darwin NSProcessInfo activity assertion helpers
 *
 * Keeps the process (and by extension its Darwin coalition) opted out of
 * App Nap / background suppression while QEMU is running, so a GUI parent
 * losing frontmost status does not demote our CPU QoS, timer coalescing,
 * or disk I/O tier.
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#ifndef QEMU_DARWIN_ACTIVITY_H
#define QEMU_DARWIN_ACTIVITY_H

#ifdef CONFIG_DARWIN
void qemu_darwin_begin_vm_activity(const char *reason);
void qemu_darwin_end_vm_activity(void);
#else
static inline void qemu_darwin_begin_vm_activity(const char *reason) { }
static inline void qemu_darwin_end_vm_activity(void) { }
#endif

#endif /* QEMU_DARWIN_ACTIVITY_H */
