// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

/*
 * Pin glibc NSS to its built-in services in the static openshell-sandbox.
 *
 * openshell-sandbox is linked statically against glibc and runs inside
 * arbitrary agent images. Static glibc still honors the image's
 * /etc/nsswitch.conf and dlopen()s every listed module other than the
 * built-in "files" and "dns" (for example myhostname, resolve, systemd or
 * sss). The module pulls the image's libc.so.6 into the process, which
 * crashes it whether or not that glibc matches the one we link (RHAI-1927).
 *
 * This constructor runs before main() and limits every NSS database to the
 * built-in services, so lookups behave like upstream's musl build: users and
 * groups come from /etc/passwd and /etc/group, hosts from /etc/hosts and DNS.
 * The override is per-process and does not survive exec(), so workloads
 * started by the sandbox keep the image's normal NSS configuration.
 *
 * Linked into the binary by deploy/docker/Dockerfile.konflux.sandbox.
 */

#include <stddef.h>
#include <string.h>
#include <unistd.h>

/* Exported by glibc but not declared in its public headers. */
extern int __nss_configure_lookup(const char *dbname, const char *service_line);

/*
 * Every database glibc resolves through nsswitch.conf (nss/databases.def).
 * The passwd_compat, group_compat and shadow_compat databases are only read
 * by nss_compat, which is never loaded once passwd, group and shadow are
 * pinned to files.
 */
static const struct {
    const char *db;
    const char *services;
} pinned[] = {
    {"aliases", "files"},
    {"ethers", "files"},
    {"group", "files"},
    {"gshadow", "files"},
    {"hosts", "files dns"},
    {"initgroups", "files"},
    {"netgroup", "files"},
    {"networks", "files dns"},
    {"passwd", "files"},
    {"protocols", "files"},
    {"publickey", "files"},
    {"rpc", "files"},
    {"services", "files"},
    {"shadow", "files"},
};

static void warn_unpinned(const char *db) {
    /* Load-bearing: Dockerfile.konflux.sandbox greps the binary for "failed
     * to pin NSS database" to check the pin is linked. Update both together. */
    static const char msg[] = "openshell-sandbox: warning: failed to pin NSS database ";

    (void)!write(STDERR_FILENO, msg, sizeof(msg) - 1);
    (void)!write(STDERR_FILENO, db, strlen(db));
    (void)!write(STDERR_FILENO, "\n", 1);
}

__attribute__((constructor)) static void openshell_pin_nss(void) {
    for (size_t i = 0; i < sizeof(pinned) / sizeof(pinned[0]); i++) {
        if (__nss_configure_lookup(pinned[i].db, pinned[i].services) != 0) {
            warn_unpinned(pinned[i].db);
        }
    }
}
