// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

/*
 * Static glibc binaries cannot safely load NSS modules from an arbitrary
 * workload image. Configure every glibc NSS database before Rust startup so
 * lookups use only services built into libc.
 */

extern int __nss_configure_lookup(const char *database, const char *service_line);

static void __attribute__((constructor)) configure_static_nss(void)
{
    static const char *const file_databases[] = {
        "aliases", "ethers",   "group",     "gshadow",  "initgroups",
        "netgroup", "networks", "passwd",    "protocols", "publickey",
        "rpc",      "services", "shadow",
    };
    unsigned long i;

    for (i = 0; i < sizeof(file_databases) / sizeof(file_databases[0]); ++i)
        (void)__nss_configure_lookup(file_databases[i], "files");

    (void)__nss_configure_lookup("hosts", "files dns");
}
