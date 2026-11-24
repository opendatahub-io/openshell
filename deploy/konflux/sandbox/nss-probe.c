// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

/*
 * Build-time check for pin-nss.c, used by Dockerfile.konflux.sandbox.
 *
 * Built with -DNSS_PROBE_MODULE, this is a fake NSS module
 * (libnss_openshellprobe.so.2) that answers every UID. It has no libc
 * dependency, so glibc can load it into a static binary on any architecture,
 * which makes it a deterministic stand-in for modules such as libnss_systemd.
 *
 * Built without it, this is a static probe that looks up a UID no real
 * database has. It exits 1 when the fake module answered, meaning NSS
 * consulted a non-built-in module, and 0 when the lookup found nothing.
 *
 * The negative control relies on static glibc still dlopen()ing NSS modules.
 * If a future glibc stops doing that, the unpinned probe exits 0 and the
 * build fails; the pin, and this check, can then be dropped.
 */

#include <nss.h>
#include <pwd.h>
#include <stddef.h>

#ifdef NSS_PROBE_MODULE

enum nss_status _nss_openshellprobe_getpwuid_r(uid_t uid, struct passwd *pwd,
                                               char *buf, size_t buflen,
                                               int *errnop) {
    static char name[] = "openshell-nss-probe";

    (void)buf;
    (void)buflen;
    (void)errnop;
    pwd->pw_name = name;
    pwd->pw_passwd = name;
    pwd->pw_uid = uid;
    pwd->pw_gid = uid;
    pwd->pw_gecos = name;
    pwd->pw_dir = name;
    pwd->pw_shell = name;
    return NSS_STATUS_SUCCESS;
}

#else

int main(void) {
    return getpwuid(2147483646) != NULL;
}

#endif
