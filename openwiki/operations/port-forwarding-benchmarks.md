---
type: benchmark-operations
title: Port Forwarding Benchmark Design, Results, and Reproduction
description: Historical forwarding measurements, workload semantics, retained transport decisions, comparison limits, and reproducible loopback commands.
tags: [ssh, port-forwarding, benchmark, performance, openssh]
verified:
  - by: openwiki/0.5.2
    at: 2026-09-22T01:13:21.371Z
sources:
  - id: openwiki-source-7f5c1cb6f348742514987bf8
    resource: repo://Benchmarks/PortForwarding/main.swift
  - id: openwiki-source-20118197848107cfa8e87aa9
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHForwardingConnectionPool.swift
  - id: openwiki-source-5fd6c7173f1d0c9e61b8091d
    resource: repo://Scripts/benchmark-external-port-forwarding.py
  - id: openwiki-source-d32eeff4d814c0dbd05e14b8
    resource: repo://Scripts/benchmark-port-forwarding.py
  - id: openwiki-source-61e25d353d86139455e8edbd
    resource: repo://Scripts/ssh-forwarding-openssh-fixture.py
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
generated: { by: "codex", at: "2026-09-22T01:13:21.371Z" }
---

# Port Forwarding Benchmark Design, Results, and Reproduction

This page preserves measurements taken on 2026-09-19 and 2026-09-20. They are historical engineering evidence, not current capacity claims, WAN predictions, or CI thresholds. The recorded machine was an M3 Pro with 36 GiB running macOS 26.6.2; the final OpenSSH comparison used Xcode 27.1 (27A9269).

## Retained transport decisions

- `SSHBufferedTransport`, socket readiness, immutable byte queues, and deduplicated ready queues are shared nonblocking primitives for forwarding, Agent exec, PTY, and jump bridges. Port Forwarding still owns rule/listener/flow policy; shared primitives do not merge feature authentication or recovery lifetimes.
- Local, remote, dynamic, and jump pumps are readiness-driven under one serial libssh2 owner per session, without bulk polling. Preserve immutable write address/length across EAGAIN, drain accepted bytes before half-close, cancel sources before closing descriptors, and keep pending channel/listener operations across retries.
- Scheduling uses a deduplicated ready FIFO, 2 ms slice, 256 KiB per-direction quantum, and 256 KiB/session encrypted-read allowance, including reads caused by writes. Callbacks and inner loops honor the deadline; continuations reset yield state. Socket readiness queues its own flow, protocol progress wakes peers, and remote admission runs before and after bulk I/O.
- Output batches at most 16 immutable iovecs through nonblocking `sendmsg`; both encrypted flushes share 256 KiB/pass. Channel chunks are 32,700 bytes to match the pinned libssh2 write clamp, avoiding a second packet for a 68-byte tail. Historical alignment comparison reduced encrypted writes from about 66.5 to 38.6 per payload MiB.
- Plaintext queues pause at 2 MiB per direction/flow and resume below 1 MiB. Encrypted output pauses at 2 MiB/session with bounded current-operation overshoot. Library windows, kernel buffers, stacks, and app memory are additional; these are not a global cap for unlimited connections. DNS has four workers, numeric addresses bypass them, and nonblocking target TCP has a five-second deadline.
- Public send/receive callbacks queue complete encrypted packets and apply backpressure outside libssh2 calls. This avoids the pinned library's `packet_queue_listener` dropping forwarded-tcpip channels when confirmation encounters EAGAIN; no dependency pin or private ABI changes were used. Teardown discards writes and returns EOF.
- Jump socketpairs request 256 KiB send/receive buffers on macOS and 64 KiB on iOS for both endpoints, best effort and without shrinking larger defaults. Recorded Mac defaults were 8 KiB. Kernel capacity remains separate from application watermarks and the encrypted-read allowance.

## Harness and measurement semantics

`Benchmarks/PortForwarding/main.swift` is a standalone Release command-line target. It validates every payload and EOF before emitting metrics; dedicated client threads avoid Dispatch worker starvation. TFMTests and TFITests retain functional wire coverage, but neither a test bundle nor Termind.app hosts the benchmark.

The complete workload matrix is:

- request/response: 1, 16, or 64 streams, nine 64 KiB exchanges each;
- duplex: 1, 16, or 64 streams, 129 × 64 KiB in each direction per stream, with independent producers and consumers;
- jumps: each forwarding kind, 16 streams, through one or two bridges;
- mixed: eight bulk streams plus sixteen 64-byte request streams, direct or through one/two jumps; and
- lifecycle: slow consumer, backpressured disconnect, independent/cancelled listeners, reuse, fragmented SOCKS, and a five-second idle two-jump connection.

Throughput is useful payload per direction. Elapsed time includes setup. Ready p95 includes connect, channel, target, first probe, and SOCKS negotiation where applicable; request latency starts afterward, so a low request p95 can hide slow admission. CPU is whole benchmark host plus clients but excludes the server. RSS is process-lifetime peak, not transport-only or per-flow allocation. Runs were sequential Release hosts without competing builds/suites, though ordinary desktop apps remained active. Encrypted loopback does not establish WAN, physical-iOS, or proportional multi-connection behavior.

## Multi-connection and system-SSH modes

`Scripts/benchmark-port-forwarding.py` builds the standalone Release runner once and accepts an ordered, deduplicated list of Termind maximum-connection values from 1 through 64; the default is one. Local and dynamic rules may use the pool. Remote forwarding remains on the primary worker regardless of that maximum.

`Scripts/benchmark-external-port-forwarding.py system-ssh` measures one macOS `/usr/bin/ssh` process and one direct connection for Local, Dynamic, and Remote using `ssh -N -L`, `-D`, and `-R`. Its `external` mode measures an already-running third-party listener as a direct single-connection black box. Manual mode reports network metrics only because it cannot attribute startup, CPU, or RSS to a process it does not own. Both scripts use the same record and median JSON shape.

```sh
python3 Scripts/benchmark-port-forwarding.py \
  --metadata /tmp/termind-openssh.json \
  --output /tmp/termind-forwarding.json \
  --termind-connections 1 4 16 64

python3 Scripts/benchmark-external-port-forwarding.py \
  --metadata /tmp/termind-openssh.json \
  --output /tmp/system-ssh-forwarding.json \
  system-ssh
```

## Historical connection-pool result

These five-run medians were recorded on the M3 Pro, macOS 26.6.2, Xcode 27.0 Release (`-O`, `ENABLE_TESTABILITY=YES`) with the loopback OpenSSH fixture. MiB/s is useful throughput per direction. This table compares historical Termind configurations with one another, not with the later single-connection system-SSH baseline.

| Direct workload | 1 connection | 4 connections | Ratio |
| --- | ---: | ---: | ---: |
| Local request/response, 16 streams | 127.3 | 244.6 | 1.92× |
| Local request/response, 64 streams | 186.3 | 371.5 | 1.99× |
| Local duplex, 16 streams | 176.4 | 537.7 | 3.05× |
| Local duplex, 64 streams | 166.7 | 376.5 | 2.26× |
| Dynamic request/response, 16 streams | 174.7 | 398.0 | 2.28× |
| Dynamic request/response, 64 streams | 184.1 | 315.7 | 1.71× |
| Dynamic duplex, 16 streams | 170.7 | 418.6 | 2.45× |
| Dynamic duplex, 64 streams | 171.5 | 332.5 | 1.94× |

At 16 streams, Local request/response CPU rose 46% for 92% more throughput; Dynamic CPU rose 20% for 128% more throughput. Remote medians stayed within 5%, as intended. Extra full-route connections helped less as jump cost increased: Local 16-stream request/response was 1.77× with one jump and 1.14× with two; Dynamic was 1.26× and 1.00×. At 64 request/response streams, aggregate throughput improved while request p95 sometimes regressed. Maximum connections is therefore a throughput/concurrency control, not a universal latency improvement.

The JSON output retains each sample plus medians for useful MiB/s/direction, ready/request p95, aggregate CPU, peak RSS, macOS, and OpenSSH versions. Compression was disabled. Do not use these loopback numbers as WAN expectations or regression thresholds.

## Historical baseline-to-final OpenSSH comparison

The baseline was the four forwarding implementation files at commit `d53f37cd`. The following are five-run medians against the same loopback OpenSSH fixture and Release harness; they are not directly comparable to older Paramiko data.

| Workload | Baseline → final MiB/s/direction | Baseline → final CPU ms/total MiB |
| --- | ---: | ---: |
| Local, 64 duplex | 159.2 → 176.1 | 2.82 → 2.70 |
| Dynamic, 64 duplex | 159.6 → 178.2 | 2.84 → 2.68 |
| Remote, 64 duplex | 159.5 → 158.6 | 3.00 → 2.96 |
| Mixed, direct | 163.5 → 175.4 | 3.15 → 3.06 |
| Mixed, one jump | 94.6 → 175.7 | 8.09 → 5.78 |
| Mixed, two jumps | 94.4 → 164.1 | 11.82 → 8.40 |

| Mixed workload | Ready p95 ms, baseline → final | Small-request p95 ms, baseline → final |
| --- | ---: | ---: |
| Direct | 205.3 → 213.9 | 18.1 → 16.5 |
| One jump | 570.8 → 330.8 | 16.9 → 5.1 |
| Two jumps | 470.3 → 295.2 | 19.2 → 11.7 |

The repeatable result was higher jump throughput and lower CPU per byte, with smaller direct gains and flat Remote-64 throughput. Remote-64 readiness worsened from 11.5 to 14.1 ms; final Local-64 and Dynamic-64 readiness remained 1,873 and 1,721 ms. Three alternating baseline/candidate pairs also improved one/two-jump throughput from 93.8 to 173.3 and 89.2 to 156.1 MiB/s, but they preceded the final admission sweep and cannot attribute later gains to that sweep alone.

### Rejected larger read-ahead

A 4 MiB receive allowance did not fix jump bottlenecks before socketpair tuning and raised median whole-process peak RSS from 262 to 505 MiB; 1 MiB yielded 464 MiB. The conservative 256 KiB candidate recorded 261 MiB and alternating baseline/candidate maxima of 262/262 MiB. Final 228–243 MiB peaks do not prove a transport-only memory reduction. Four-MiB socketpair requests offered no consistent benefit. Single-stream cases lasted about 40 ms and were noisy; physical iOS remained unmeasured.

## Provenance limits

Earlier three-run Paramiko medians showed direct duplex around 66–70 MiB/s/direction and Remote-64 readiness around 1.79 seconds, with highly variable mixed admission and small-request latency. A bridge-only swap improved 16-stream request throughput by 9.6–14.4× and two-jump idle CPU from 0.485–0.531 to 0.110–0.123 seconds per five seconds, including app/test-host overhead.

The unmodified `5c88a2bf` revision produced no successful metric records because of EAGAIN, listener, and SOCKS failures, so no whole-application speedup can be calculated from it. The bridge comparison kept the new worker and swapped only `SSHRoutedSocket.swift`.

The original report named `PORT_FORWARDING_BENCHMARK.json` and `PORT_FORWARDING_OPTIMIZATION_BENCHMARK.json`; neither raw file is tracked. The latter was described as 1,512 records and 56 successful full runs, but the tables above are retained summaries rather than independently rechecked raw data. Zero-test attempts, a failed Remote-64 Debug EOF run, and an unsupported OpenSSH delayed-listener smoke were not measurements. Historical focused/lifecycle/build checks passed while unrelated full-suite failures remained; they do not establish current regression status.

## Reproduction

Use the loopback-only temporary OpenSSH fixture with ephemeral keys, public-key authentication, restricted SSH/echo destinations, and `MaxSessions 0`. It does not modify system SSH or `authorized_keys`. Metadata and the temporary client key are private mode 0600; stop the fixture normally to remove them.

```sh
python3 Scripts/ssh-forwarding-openssh-fixture.py --metadata /tmp/termind-openssh.json
```

In another terminal:

```sh
python3 Scripts/benchmark-port-forwarding.py \
  --metadata /tmp/termind-openssh.json \
  --output /tmp/termind-forwarding.json \
  --termind-connections 1 4
```

The script builds `TermindPortForwardingBenchmark` with ordinary Release optimization, without `ENABLE_TESTABILITY`, Termind.app, or XCTest, then launches a fresh process for each connection limit and repetition. `--quick` reduces repetitions to one but retains the full workload matrix. Do not benchmark beside builds or competing traffic.

For an already-configured direct Local or Remote forward to the fixture's `echoPort`, or a Dynamic SOCKS5 listener, run one kind at a time:

```sh
python3 Scripts/benchmark-external-port-forwarding.py \
  --metadata /tmp/termind-openssh.json \
  --output /tmp/external-forwarding.json \
  external --name "External SSH Client" --kind local --port 50000
```

The deliberately delayed remote-listener case uses a temporary environment with `paramiko==4.0.0` and `python Scripts/ssh-authentication-fixture.py --metadata /tmp/ssh-fixture.json`, substituting that metadata path. Other wire/lifecycle cases run against both fixtures.

See [Remote Services: Terminal, Metrics, and Port Forwarding](/openwiki/concepts/remote-services-and-forwarding.md) for current runtime behavior and [SSH, Telnet, Trust, and Workspace Session Lifecycle](/openwiki/workflows/ssh-session-lifecycle.md) for authentication and transport ownership.
