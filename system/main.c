/*
 * QEMU System Emulator
 *
 * Copyright (c) 2003-2020 Fabrice Bellard
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include "qemu/osdep.h"
#include "qemu-main.h"
#include "qemu/main-loop.h"
#include "system/darwin-activity.h"
#include "system/replay.h"
#include "system/system.h"

#ifdef CONFIG_SDL
/*
 * SDL insists on wrapping the main() function with its own implementation on
 * some platforms; it does so via a macro that renames our main function, so
 * <SDL.h> must be #included here even with no SDL code called from this file.
 */
#include <SDL.h>
#endif

#ifdef CONFIG_DARWIN
#include <CoreFoundation/CoreFoundation.h>
#include <sys/resource.h>
#endif

static void *qemu_default_main(void *opaque)
{
    int status;

#ifdef CONFIG_DARWIN
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    {
        struct sched_param param;
        param.sched_priority = sched_get_priority_max(SCHED_RR);
        pthread_setschedparam(pthread_self(), SCHED_RR, &param);
    }
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_IMPORTANT);
    setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_THREAD,
                   IOPOL_ATIME_UPDATES_OFF);
#endif

    replay_mutex_lock();
    bql_lock();
    status = qemu_main_loop();
    qemu_cleanup(status);
    bql_unlock();
    replay_mutex_unlock();

    qemu_darwin_end_vm_activity();

    exit(status);
}

int (*qemu_main)(void);

#ifdef CONFIG_DARWIN
static int os_darwin_cfrunloop_main(void)
{
    CFRunLoopRun();
    g_assert_not_reached();
}
int (*qemu_main)(void) = os_darwin_cfrunloop_main;
#endif

int main(int argc, char **argv)
{
#ifdef CONFIG_DARWIN
    /*
     * Raise the default disk I/O tier for the whole process before any
     * thread is spawned. Threads we explicitly tune (iothread, aio worker
     * pool, this main thread) set IOPOL_SCOPE_THREAD individually, but this
     * process-scope default covers everything else (QMP monitor, VNC, char
     * device helpers, migration, etc.) and any future threads we forget
     * about. Without it, coalition-level backgrounding (e.g. when the
     * hosting GUI app is not frontmost) demotes our default-STANDARD I/O
     * into the kernel's throttled tier under contention.
     */
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT);
    setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_PROCESS,
                   IOPOL_ATIME_UPDATES_OFF);
#endif

    /*
     * Hold an NSProcessInfo activity assertion for the lifetime of the
     * process. Coalition-level backgrounding (triggered when a parent GUI
     * app loses frontmost status) otherwise demotes our scheduler QoS and
     * I/O tier for the whole process tree; this keeps us marked
     * user-initiated / latency-critical regardless of who launched us.
     */
    qemu_darwin_begin_vm_activity("QEMU running guest VM");

    qemu_init(argc, argv);

    /*
     * qemu_init acquires the BQL and replay mutex lock. BQL is acquired when
     * initializing cpus, to block associated threads until initialization is
     * complete. Replay_mutex lock is acquired on initialization, because it
     * must be held when configuring icount_mode.
     *
     * On MacOS, qemu main event loop runs in a background thread, as main
     * thread must be reserved for UI. Thus, we need to transfer lock ownership,
     * and the simplest way to do that is to release them, and reacquire them
     * from qemu_default_main.
     */
    bql_unlock();
    replay_mutex_unlock();

    if (qemu_main) {
        QemuThread main_loop_thread;
        qemu_thread_create(&main_loop_thread, "qemu_main",
                           qemu_default_main, NULL, QEMU_THREAD_DETACHED);
        return qemu_main();
    } else {
        qemu_default_main(NULL);
        g_assert_not_reached();
    }
}
