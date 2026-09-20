# Port forwarding performance

Historical measurements from 2026-09-19, not current capacity or suite-pass claims. Hardware: M3 Pro/36 GiB,
macOS 26.6.2; final OpenSSH runs used Xcode 27.1 (27A9269). See [architecture](ARCHITECTURE.md) for lifecycle/auth rules.

## Design decisions worth retaining

- `SSHBufferedTransport`, socket readiness, immutable byte queues and deduplicated ready queues are now the common
  nonblocking transport primitives for forwarding, multiplexed Agent exec, PTY and jump bridges. Port Forwarding still
  owns its rule/listener/flow policy; sharing primitives does not merge feature authentication or recovery lifetimes.
- Local/remote/SOCKS and jump bridges share readiness-driven pumps, one serial libssh2 owner/session. No bulk polling.
  Preserve immutable write address/length across EAGAIN, drain accepted bytes before half-close, cancel sources before
  descriptor close, and retain pending channel/listener operations across retries.
- Deduplicated ready FIFO, 2 ms slice, 256 KiB per-direction quantum and 256 KiB/session encrypted-read allowance
  (including reads inside writes). Callbacks/inner loops honor the deadline; continuations reset yield state. Socket
  readiness queues its own flow; protocol progress wakes peers. Remote admission runs before and after bulk I/O.
- Output batches at most 16 immutable iovecs with nonblocking `sendmsg`; both encrypted flushes share 256 KiB/pass.
  Channel chunks are 32,700 bytes to match pinned libssh2's write clamp, avoiding a second packet for a 68-byte tail.
  Alignment comparison reduced encrypted writes from ~66.5 to ~38.6 per payload MiB.
- Plaintext queues pause at 2 MiB/direction/flow, resume below 1 MiB. Encrypted output pauses at 2 MiB/session with
  bounded current-operation overshoot. Library windows, kernel buffers, stacks and app memory are additional;
  these are not a global cap for unlimited connections. DNS has four workers; numeric addresses bypass them;
  nonblocking target TCP has a five-second deadline.
- Public send/receive callbacks queue **complete encrypted packets**, applying backpressure outside library calls.
  This avoids pinned libssh2 `packet_queue_listener` dropping a forwarded-tcpip channel when confirmation hits EAGAIN;
  neither dependency pins nor private ABI changed. Teardown discards writes/returns EOF.
- Jump socketpairs request 256 KiB send/receive buffers on macOS, 64 KiB on iOS, both endpoints, best-effort without
  shrinking larger defaults. Measured Mac defaults were 8 KiB. No global sysctl/TCP changes; kernel capacity is
  separate from read allowance/application watermarks.

## Workload and measurement limits

`Benchmarks/PortForwarding/main.swift` validates every payload and EOF before printing metrics from a standalone
Release command-line target; dedicated client threads avoid Dispatch worker starvation. Functional forwarding wire
coverage remains in TFMTests and TFITests, but neither test bundle nor Termind.app hosts the benchmark.

- Request/response: 1/16/64 streams, nine 64 KiB exchanges each.
- Duplex: 1/16/64 streams, 129 × 64 KiB per direction/stream, independent producers/consumers.
- Jumps: each forwarding kind, 16 streams, one/two bridges.
- Mixed: eight bulk plus sixteen 64-byte request streams, 0/1/2 jumps.
- Lifecycle: slow consumer, backpressured disconnect, independent/cancelled listeners, reuse, fragmented SOCKS; idle two-jump connection for five seconds.

Throughput is useful payload **per direction**, elapsed includes setup. Ready p95 includes connect/channel/target/first
probe (and SOCKS negotiation); request latency starts afterward. Low request latency can hide slow admission. CPU is
whole app/test-host+clients, excludes server. RSS is process-lifetime peak, not transport-only/per-flow allocation.
Runs were sequential Release hosts without competing builds/suites; ordinary desktop apps remained active.
Encrypted loopback does not establish WAN, physical-iOS or proportional multi-connection bandwidth.

## Multi-connection and system SSH comparison

`Scripts/benchmark-port-forwarding.py` builds the standalone Release runner once and accepts any ordered, deduplicated
list of Termind Max Connections values from one through 64. The default is one. Remote forwarding remains single-worker
regardless of the configured maximum.

`Scripts/benchmark-external-port-forwarding.py system-ssh` automatically measures one macOS `/usr/bin/ssh` process and
one direct SSH connection for Local, Dynamic and Remote using `ssh -N -L`, `-D` and `-R`. Its `external` mode measures one
already-running third-party listener as a direct, single-connection black box. The manual mode reports network metrics
only; it cannot include application startup, CPU or RSS without owning that process. Both scripts emit the same records
and median JSON shape for offline comparison.

### Release connection-pool result (2026-09-20)

Five-run medians on Apple M3 Pro, macOS 26.6.2, Xcode 27.0 Release (`-O`, `ENABLE_TESTABILITY=YES`), using the
loopback OpenSSH fixture. Throughput is useful MiB/s per direction; these results compare Termind with itself, not the
current single-connection system SSH baseline.

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

At 16 streams, Local request/response CPU rose 46% for 92% more throughput; Dynamic CPU rose 20% for 128% more
throughput. Remote medians stayed within 5%, as intended. Extra full-route connections help less as jump cost grows:
Local 16-stream request/response was 1.77× with one jump and 1.14× with two; Dynamic was 1.26× and 1.00×. At 64
request/response streams, aggregate throughput improved while request p95 sometimes regressed, so Max Connections is a
throughput/concurrency control rather than a universal per-request latency win.

The JSON output retains every sample plus five-run medians for useful MiB/s/direction, ready/request p95, aggregate CPU
and peak RSS. It records macOS and OpenSSH versions. Compression is disabled. Do not treat loopback medians or the
system reference as universal WAN results or CI thresholds.

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

## Final OpenSSH comparison

Baseline: four forwarding implementation files at `d53f37cd`. Five-run medians, same OpenSSH fixture and Release
harness; do not compare these numbers directly to earlier Paramiko results.

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

Repeatable result: higher jump throughput/lower CPU per byte; direct gains smaller, remote64 throughput flat.
Remote64 readiness worsened 11.5 → 14.1 ms; local64/dynamic64 final readiness remained 1,873/1,721 ms. No universal
latency-win claim. Three alternating baseline/candidate pairs also improved one/two-jump throughput (93.8 → 173.3,
89.2 → 156.1 MiB/s); they preceded the final admission sweep, so do not attribute later throughput changes to that
sweep alone.

### Why not larger read-ahead?

A 4 MiB receive allowance did not fix jump bottlenecks before socketpair tuning and raised median whole-process
peak RSS from 262 to 505 MiB; 1 MiB yielded 464 MiB. The 256 KiB conservative candidate was 261 MiB, alternating
baseline/candidate maxima 262/262 MiB. Final peaks 228–243 MiB do not prove transport-only memory reduction.
4 MiB socketpair requests offered no consistent benefit. Keep bounded memory/repeatable gains; physical iOS remains
unmeasured. Single-stream cases last ~40 ms and are noisy.

### Earlier evidence and provenance

- Three-run Paramiko medians: direct duplex ~66–70 MiB/s/direction, remote64 readiness ~1.79 s; mixed admission and
  small-request latencies varied widely. A bridge-only swap improved 16-stream request throughput 9.6–14.4× and
  two-jump idle CPU from 0.485–0.531 to 0.110–0.123 s/five seconds, including app/test overhead.
- Unmodified `5c88a2bf` completed no successful metric records (EAGAIN/listener/SOCKS failures). No whole-application
  speedup can be computed. The bridge comparison kept the new worker and replaced only `SSHRoutedSocket.swift`.
- The original report referenced `PORT_FORWARDING_BENCHMARK.json` and
  `PORT_FORWARDING_OPTIMIZATION_BENCHMARK.json` (latter: 1,512 records/56 successful full runs). Neither artifact is
  tracked in this repository; tables here are retained historical summaries, not independently rechecked raw data.
  Zero-test attempts, failed remote64 Debug EOF and unsupported OpenSSH delayed-listener smoke were not measurements.
- Historical focused/lifecycle/build checks passed, but full suites were not green: macOS StoreKit hang/Metrics toolbar
  failures and mobile rendering/upload/editor issues were recorded. Those runs establish neither current regression
  status nor a full-suite pass; rerun risk-appropriate tests after transport changes.

## Reproduction

Preferred fixture: loopback-only temporary OpenSSH with ephemeral keys, public-key auth, restricted SSH/echo destinations,
`MaxSessions 0`; no changes to system SSH or authorized_keys. Metadata is private (0600, temporary client key); stop the
fixture normally to remove it/keys.

```sh
python3 Scripts/ssh-forwarding-openssh-fixture.py --metadata /tmp/termind-openssh.json
```

In another terminal, run Termind's complete Release matrix:

```sh
python3 Scripts/benchmark-port-forwarding.py \
  --metadata /tmp/termind-openssh.json \
  --output /tmp/termind-forwarding.json \
  --termind-connections 1 4
```

The script builds `TermindPortForwardingBenchmark` with ordinary Release optimization, without `ENABLE_TESTABILITY`,
Termind.app or XCTest. It then launches a fresh runner process for every connection limit and repetition. `--quick`
reduces repetitions to one but retains the complete Termind workload matrix. Do not benchmark beside builds or other
traffic.

For a manually configured client, create a direct Local or Remote forward to the metadata file's `echoPort`, or a
Dynamic SOCKS5 listener, then run one kind at a time:

```sh
python3 Scripts/benchmark-external-port-forwarding.py \
  --metadata /tmp/termind-openssh.json \
  --output /tmp/external-forwarding.json \
  external --name "External SSH Client" --kind local --port 50000
```

For the deliberately delayed remote-listener case, use a temporary venv with `paramiko==4.0.0` and
`python Scripts/ssh-authentication-fixture.py --metadata /tmp/ssh-fixture.json`, substituting that metadata path above.
Other wire/lifecycle cases run against both fixtures.
