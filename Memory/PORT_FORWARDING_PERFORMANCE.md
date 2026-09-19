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

`TFMTests/SSHForwardingWireTests.swift` validates every payload and EOF before printing metrics; dedicated client
threads avoid Dispatch worker starvation. The forwarding test sources also compile in TFITests.

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

In another terminal:

```sh
TEST_RUNNER_TERMIND_SSH_FIXTURE=/tmp/termind-openssh.json \
TEST_RUNNER_TERMIND_FORWARDING_BENCHMARK=1 \
xcodebuild -project Termind.xcodeproj -scheme TFM \
  -destination 'platform=macOS,arch=arm64' \
  -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:TFMTests/SSHForwardingWireTests test
```

This command is Debug. Recorded Release runs used an isolated worktree with
`-configuration Release ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES`, excluding FrameworkTests/unrelated Debug-only
TFM tests and linking existing ScrubberKit into the Release test host equally for both versions. These harness-only
changes were not submitted. Repetitions used `test-without-building`; do not benchmark beside builds/other traffic.

For the deliberately delayed remote-listener case, use a temporary venv with `paramiko==4.0.0` and
`python Scripts/ssh-authentication-fixture.py --metadata /tmp/ssh-fixture.json`, substituting that metadata path above.
Other wire/lifecycle cases run against both fixtures.
