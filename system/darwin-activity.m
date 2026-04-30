/*
 * Darwin NSProcessInfo activity assertion helpers
 *
 * Copyright (c) 2024 QEMU authors
 *
 * Holds an NSProcessInfo activity token for the lifetime of the QEMU
 * process. The token opts this process (and by coalition aggregation any
 * children we spawn or parents that spawned us) out of App Nap and
 * background-state suppression, which on Darwin would otherwise demote
 * CPU QoS, timer coalescing, and disk I/O tier when the hosting GUI app
 * loses frontmost status.
 *
 * This complements the per-thread / process-scope setiopolicy_np calls
 * in iothread.c, util/thread-pool.c, and system/main.c: those pin our
 * disk I/O tier to IOPOL_IMPORTANT, this keeps the kernel from deciding
 * we're eligible for background suppression in the first place.
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#include "qemu/osdep.h"
#include "system/darwin-activity.h"

#import <Foundation/Foundation.h>

/*
 * The NSProcessInfo token is an opaque id that must be kept alive for the
 * duration of the activity. QEMU builds ObjC sources without ARC (see
 * ui/cocoa.m), so we retain the token explicitly.
 */
static id qemu_darwin_activity_token;

void qemu_darwin_begin_vm_activity(const char *reason)
{
    if (qemu_darwin_activity_token) {
        return;
    }

    @autoreleasepool {
        NSString *ns_reason = reason
            ? [NSString stringWithUTF8String:reason]
            : @"QEMU running guest VM";

        NSActivityOptions opts = NSActivityUserInitiated
                               | NSActivityLatencyCritical
                               | NSActivityIdleSystemSleepDisabled;

        id token = [[NSProcessInfo processInfo]
                       beginActivityWithOptions:opts
                                         reason:ns_reason];
        qemu_darwin_activity_token = [token retain];
    }
}

void qemu_darwin_end_vm_activity(void)
{
    if (!qemu_darwin_activity_token) {
        return;
    }

    [[NSProcessInfo processInfo] endActivity:qemu_darwin_activity_token];
    [qemu_darwin_activity_token release];
    qemu_darwin_activity_token = nil;
}
