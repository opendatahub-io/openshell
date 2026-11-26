// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! On an IPv6-only network, policy DNS answers AAAA queries for a policy
//! endpoint's host with a synthetic IPv6 address, and a connection to that
//! address reaches only the endpoint's upstream.
//!
//! The environment must give sandboxes no IPv4 default route, so the default
//! `policy_dns_ipv6_egress = "auto"` turns on, and set
//! `host.openshell.internal` to the test host's IPv6 address, as the `k3s`
//! installers do on `ubuntu-k3s-ipv6`.

use std::net::IpAddr;

use host_server_support::{HttpRecorder, TEST_HOST, allow_host, free_port};
use sandbox_clients_support::{Request, connect, http};
use testkit::Context;
use testkit::policy;

fn main() -> std::process::ExitCode {
    testkit::main()
}

/// Sends an AAAA query for `argv[1]` to the sandbox's nameserver over UDP and
/// over TCP, without proxy variables, and prints the addresses of each answer
/// as one JSON line.
const DNS_CLIENT: &str = r#"
import json, os, random, socket, struct, sys

for name in [n for n in os.environ if n.lower().endswith("_proxy")]:
    del os.environ[name]
server = next(l.split()[1] for l in open("/etc/resolv.conf") if l.startswith("nameserver"))
family = socket.AF_INET6 if ":" in server else socket.AF_INET
qid = random.randrange(65536)
query = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
query += b"".join(bytes([len(p)]) + p.encode() for p in sys.argv[1].split(".")) + b"\0"
query += struct.pack("!HH", 28, 1)

def skip_name(msg, i):
    while msg[i]:
        if msg[i] >= 0xC0:
            return i + 2
        i += msg[i] + 1
    return i + 1

def addresses(msg):
    _, flags, qd, an = struct.unpack("!HHHH", msg[:8])
    i = 12
    for _ in range(qd):
        i = skip_name(msg, i) + 4
    found = []
    for _ in range(an):
        i = skip_name(msg, i)
        rtype, _, _, length = struct.unpack("!HHIH", msg[i:i + 10])
        i += 10
        if rtype == 28:
            found.append(socket.inet_ntop(socket.AF_INET6, msg[i:i + length]))
        i += length
    return {"rcode": flags & 0xF, "addresses": found}

with socket.socket(family, socket.SOCK_DGRAM) as udp:
    udp.settimeout(5)
    udp.sendto(query, (server, 53))
    udp_answer = addresses(udp.recv(4096))
with socket.create_connection((server, 53), timeout=5) as tcp:
    tcp.sendall(struct.pack("!H", len(query)) + query)
    data = b""
    while len(data) < 2 or len(data) < 2 + struct.unpack("!H", data[:2])[0]:
        chunk = tcp.recv(4096)
        if not chunk:
            break
        data += chunk
    tcp_answer = addresses(data[2:])
print(json.dumps({"udp": udp_answer, "tcp": tcp_answer}))
"#;

/// A native client gets the same synthetic AAAA answer over UDP and TCP, and
/// reaches the policy endpoint's server through it. The sandbox denies the
/// server's real address and the synthetic address on another port.
#[testkit::test]
async fn aaaa_answer_reaches_only_the_pinned_upstream(cx: &mut Context) -> testkit::Result {
    let server = HttpRecorder::start("pinned").await?;
    let mut allowed = policy::base();
    allow_host(&mut allowed, "host_server", server.port);
    let sandbox = cx.python_sandbox("dns6", allowed).create_ready().await?;

    let reply = http(&sandbox, TEST_HOST, server.port, &Request::get("/by-name")).await?;
    testkit::ensure!(
        reply.status() == Some(200),
        "request by name failed: {reply:?}"
    );
    let real_ip = server
        .requests()
        .first()
        .and_then(|request| request.local_addr)
        .ok_or_else(|| testkit::Error::msg("the host server didn't record its address"))?
        .ip();
    testkit::ensure!(
        real_ip.is_ipv6(),
        "{TEST_HOST} reached the host server at {real_ip}, not an IPv6 address"
    );

    let answers = sandbox
        .exec(["python3", "-c", DNS_CLIENT, TEST_HOST])
        .await?
        .success()?
        .last_json()?;
    let udp = &answers["udp"]["addresses"];
    testkit::ensure!(
        udp == &answers["tcp"]["addresses"] && udp.as_array().is_some_and(|a| a.len() == 1),
        "expected one AAAA address, the same over UDP and TCP: {answers}"
    );
    let synthetic: IpAddr = udp[0]
        .as_str()
        .and_then(|address| address.parse().ok())
        .ok_or_else(|| testkit::Error::msg(format!("unparsable AAAA answer: {answers}")))?;
    testkit::ensure!(
        synthetic != real_ip,
        "the AAAA answer is the host server's real address {real_ip}"
    );

    let host_header = format!("{TEST_HOST}:{}", server.port);
    let by_address = Request::get("/by-synthetic-address").header("Host", host_header.as_str());
    let synthetic = synthetic.to_string();
    let reply = http(&sandbox, &synthetic, server.port, &by_address).await?;
    testkit::ensure!(
        reply.status() == Some(200),
        "request to the synthetic address {synthetic} failed: {reply:?}"
    );

    let other_port = free_port().await?;
    for (what, host, port) in [
        ("the real address", real_ip.to_string(), server.port),
        (
            "the synthetic address on another port",
            synthetic,
            other_port,
        ),
    ] {
        let attempt = connect(&sandbox, &host, port).await?;
        testkit::ensure!(
            attempt.outcome.is_permission_denied(),
            "expected a denial for {what} [{host}]:{port}; got {attempt:?}"
        );
    }
    Ok(())
}
