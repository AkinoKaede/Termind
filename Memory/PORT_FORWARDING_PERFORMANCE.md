# Port forwarding concurrency and transfer evaluation

Measured on 2026-09-19, Apple M3 Pro, 36 GiB RAM, macOS 26.6.2, Xcode 27.

## Implementation

Local, remote and SOCKS5 forwarding share an event-driven stream pump with jump
bridges. Socket readiness replaces the old repeating data timer. Each SSH session
still has one serial owner: SSH channels run concurrently without concurrently
calling libssh2 on the same session. A ready FIFO, per-flow transfer quantum and
session input budget bound each scheduling pass. Immutable chunks preserve the
write address and length required by libssh2 across EAGAIN.

Remote connects are nonblocking, DNS uses four resolver workers, and numeric
addresses bypass DNS workers. Half-close drains data, high/low watermarks stop
unbounded application queues, and source cancellation precedes descriptor close.
Listener/channel creation retries EAGAIN; stopping an in-flight remote listener
waits for its request and cancellation before permitting a replacement. Starting
connection counts are retained instead of resetting the UI count to zero.

The pinned libssh2 implementation clears its pending forwarded-tcpip channel when
retrying a blocked open confirmation (`packet_queue_listener` in `packet.c`). This
caused remote forwarding through jumps to stall even with the old bridge. The new
adapter uses public send/receive callbacks to queue complete encrypted packets and
apply backpressure outside the library. No dependency pins or private ABI changed.

## Method

The opt-in tests in `TFMTests/SSHForwardingWireTests.swift` use
`Scripts/ssh-authentication-fixture.py` with Paramiko 4.0.0 and loopback echo targets.
Every received payload and final EOF is checked. Metrics are printed only after all
streams complete successfully. Dedicated client threads avoid exhausting the
Dispatch worker pool used by the implementation.

- Request/response: 1, 16, 64 streams; nine 64 KiB exchanges per stream.
- Sustained duplex echo: 1, 16, 64 streams; 129 × 64 KiB per stream per direction,
  with independent producers and consumers (516 MiB per direction at 64 streams).
- Jumps: each forwarding kind, 16 streams, one and two SSH bridges.
- Mixed: eight duplex bulk streams plus sixteen 64-byte request streams, 0/1/2 jumps.
- Lifecycle: slow consumer, repeated disconnect under backpressure, independent
  listeners, in-flight listener cancellation, port reuse, fragmented SOCKS handshake.
- Idle: an established forwarding connection through two jumps, observed for five seconds.

All throughput values are useful payload **per direction**, including connection
setup in elapsed time. `ready_p95_ms` measures TCP connect, channel/target setup and
first echoed probe; SOCKS negotiation is included. Request latency starts after
that probe. CPU is user+system CPU of the entire test-host process, including test
clients; fixture CPU is excluded. RSS is the process-lifetime high-water mark,
including the app, test threads and earlier cases; it is not per-flow memory.

Three fresh Release test-host runs were made sequentially without simultaneous
builds or other test suites. Normal desktop background processes were not disabled.
Raw successful measurements are in `PORT_FORWARDING_BENCHMARK.json`.

## Results

All table entries are medians of three runs; ranges show the three-run spread.

| Kind | Streams | MiB/s/direction (range) | Ready p95 ms | CPU ms/total payload MiB |
|---|---:|---:|---:|---:|
| local | 1 | 67.3 (67.1–67.7) | 0.4 | 7.54 |
| local | 16 | 68.5 (68.5–69.5) | 91.8 | 7.48 |
| local | 64 | 66.6 (65.9–67.0) | 447.8 | 7.68 |
| remote | 1 | 69.7 (69.3–70.2) | 0.6 | 7.46 |
| remote | 16 | 69.8 (69.2–70.3) | 431.2 | 7.68 |
| remote | 64 | 67.6 (67.6–68.0) | 1790.0 | 7.74 |
| dynamic | 1 | 67.1 (66.2–67.2) | 0.6 | 7.56 |
| dynamic | 16 | 70.3 (69.9–71.7) | 167.9 | 7.31 |
| dynamic | 64 | 67.7 (65.2–67.8) | 653.7 | 7.59 |

At 64 streams, aggregate throughput remains within about 5% of the single-stream
rate, with all payloads intact. Concurrency improves service to many connections;
it does not multiply a shared session’s bandwidth. Remote connection readiness
under sustained load is noticeably slower (p95 about 1.79 s at 64 streams).

| Mixed workload jumps | MiB/s/direction | Ready p95 ms | Small request p95 ms (range) |
|---|---:|---:|---:|
| 0 | 61.0 | 119.4 | 55.9 (55.3–56.8) |
| 1 | 30.3 | 1699.4 | 56.1 (2.4–95.0) |
| 2 | 28.9 | 1457.7 | 21.4 (3.4–122.0) |

The mixed workload completes every stream, but new-channel admission remains a
latency limitation under bulk traffic, especially through jumps. The large spread
in post-setup latency reflects how much bulk traffic remains when small streams
become ready. This is not evidence of consistently low interactive latency under
saturation. Further optimization should profile admission and protocol queueing
against an OpenSSH server before changing session-sharing/authentication policy.

Across full runs, process peak RSS was 273.0, 275.3 and 272.6 MiB. The two-jump idle
sample used 0.110–0.123 CPU seconds over five seconds (2.2–2.5% of one core for the
entire app/test process). These figures include the host UI and test client overhead;
they do not establish a transport-only CPU or allocation profile.

Bridge comparison, 16 request/response streams, median of three runs on each implementation:

| Kind | Jumps | Original bridge MiB/s | New bridge MiB/s | Ratio | CPU seconds before → after |
|---|---:|---:|---:|---:|---:|
| local | 1 | 3.72 | 38.57 | 10.4× | 1.813 → 0.338 |
| local | 2 | 2.57 | 36.92 | 14.4× | 2.832 → 0.523 |
| remote | 1 | 3.75 | 36.02 | 9.6× | 1.846 → 0.339 |
| remote | 2 | 2.60 | 36.25 | 13.9× | 2.891 → 0.522 |
| dynamic | 1 | 3.62 | 38.63 | 10.7× | 1.982 → 0.335 |
| dynamic | 2 | 2.61 | 37.09 | 14.2× | 2.899 → 0.518 |

The bridge comparison improves useful throughput by 9.6–14.4× for this workload.
It also reduces CPU time to move the same payload. The original two-jump bridge
idle samples consumed 0.485–0.531 CPU seconds per five seconds, versus 0.110–0.123
with the new bridge. This comparison includes the app/test host in both cases.

## Comparison limits

The unmodified runtime at `5c88a2bf` produced no successful metric records with the
same harness: direct channel opens were treated as failures on EAGAIN, remote
listener creation returned “Would block”, and SOCKS runs could terminate the test
host. A whole-implementation throughput speedup cannot be calculated from failed
transfers. The separate bridge comparison retains the new forwarding worker and
substitutes only the original `SSHRoutedSocket.swift`; it isolates the bridge
implementation, not the complete old application and not the timer alone.

This is an encrypted loopback/Paramiko benchmark, not a WAN or OpenSSH capacity
claim. All channels share a serialized SSH session and server; increasing connection
count does not promise proportional aggregate bandwidth. Mixed-load readiness and
request latency must be considered together: a low post-setup request percentile
can hide admission delayed by existing bulk traffic.

Application plaintext buffering is bounded at 2 MiB per direction per flow, with
resume below 1 MiB. Encrypted output is paused at 2 MiB per session, with bounded
overshoot from the current pump/control operations. libssh2 windows, socket buffers,
thread stacks and app memory are additional. These are per-flow/session bounds,
not a fixed total-memory cap for an unlimited number of connections.

## Reproduction

Create a temporary virtualenv, install `paramiko==4.0.0`, then run:

```sh
python Scripts/ssh-authentication-fixture.py --metadata /tmp/ssh-fixture.json
```

In a second terminal:

```sh
TEST_RUNNER_TERMIND_SSH_FIXTURE=/tmp/ssh-fixture.json \
TEST_RUNNER_TERMIND_FORWARDING_BENCHMARK=1 \
xcodebuild -project Termind.xcodeproj -scheme TFM \
  -destination 'platform=macOS,arch=arm64' \
  -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:TFMTests/SSHForwardingWireTests test
```

That command uses Debug. Release measurements used an isolated worktree with
`-configuration Release ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES`. The existing
Release test host needed two harness-only adjustments, applied equally before and
after: exclude FrameworkTests and unrelated Debug-only TFM tests from that host;
link the existing ScrubberKit package product in TFM's Release target. No such
project/dependency changes were made in the submitted tree. Subsequent repetitions
used `test-without-building`, with the same environment variables. Do not benchmark
alongside builds, simulator rendering tests, or other traffic generators.

## Validation and outstanding suite failures

- Final macOS targeted run: **56 tests passed**, covering forwarding, deterministic
  pump/callback tests, authentication, controller journey and architecture boundaries.
- Shared frameworks: **335 tests passed** on macOS; also **335 passed** in the iOS run.
- Release harness: all three complete performance runs passed, with 27 successful
  metric records each, plus lifecycle and idle cases.
- Final iOS Simulator app build passed. Repository-wide strict Swift formatting,
  Chinese localization validation and Python syntax checks passed.
- The full macOS suite was attempted but did not finish cleanly: the StoreKit annual
  product test hung and was interrupted. Timing-sensitive Agent/forwarding-rendering
  failures passed in the focused rerun; three language variants of
  `MetricsDetailToolbarTests.legacyCompactSearchOpensTheNativeFieldAndKeepsItsQueryWhenWidened`
  still failed. No Metrics UI code was changed.
- Full iOS app suite: 319 tests completed with nine issues in
  `MobileSavedNameRenderingTests`, `MobileUploadBatchTests`, `MobileEditorToolbarTests`
  and `MobileForwardingRenderingTests`. Its observer remained running after test
  output and was interrupted. These failures were not repaired as part of this
  transport change; the full repository suite is **not all green**.

## Follow-up: bounded batching and jump socket capacity (2026-09-19)

The next optimization keeps the 256 KiB session receive allowance. It batches
socket output with up to 16 iovecs using `sendmsg(MSG_DONTWAIT)`, limits queued
encrypted flushing to 256 KiB across both flushes in a pass, and checks the shared
2 ms deadline inside stream loops and receive callbacks. Deadline continuations
and control-only turns explicitly reset yield state. Local socket events enqueue
their own flow; SSH progress still wakes peers because libssh2 can decode packets
for another channel. Remote accepts now run before and after bulk I/O.

Channel input uses 32,700-byte chunks, matching the write clamp in the bundled
libssh2 source (`libssh2-spm` package 2.0.3, library header `1.11.1_DEV`). The old
32,768-byte chunks generated another encrypted packet for each 68-byte tail.
Single-stream encrypted socket writes fell from approximately 66.5 to 38.6 per
payload MiB in the packet-alignment comparison. Immutable write addresses/lengths
across EAGAIN, half-close draining and complete encrypted-packet acceptance remain
unchanged.

The actual Unix socketpair defaults on this Mac were only 8 KiB for both send and
receive. Jump bridges request 256 KiB on macOS and 64 KiB on iOS on both endpoints,
preserving larger existing defaults and tolerating rejected options. This changes
neither global system settings nor TCP buffer policy. These kernel buffers are
separate from the 256 KiB read allowance and 2/1 MiB application watermarks.

### OpenSSH method and retained evidence

The follow-up uses `Scripts/ssh-forwarding-openssh-fixture.py`, a temporary,
loopback-only OpenSSH server with ephemeral keys and public-key authentication.
It restricts direct destinations to its SSH and echo endpoints, disables shell,
command and subsystem sessions (`MaxSessions 0`), and changes no system SSH
configuration or user authorized_keys. The deliberately delayed remote-listen
case remains Paramiko-only; other wire/lifecycle cases run against both fixtures.

Hardware was the same M3 Pro/36 GiB Mac, macOS 26.6.2 (25G83), Xcode 27.1 (27A9269),
on AC power without reported thermal warnings. The workload, payload/EOF checking,
metric definitions and isolated Release harness adjustments described above apply.
Builds and other suites were stopped during measurements; ordinary desktop apps
remained active. The baseline is the four forwarding implementation files at
`d53f37cd`, not the much older bridge baseline in the preceding report.

`PORT_FORWARDING_OPTIMIZATION_BENCHMARK.json` retains **1,512 workload records from
56 successful full runs**: five runs for each of nine progressive variants, three
alternating baseline/candidate pairs, and five final runs after the remote-admission
adjustment. Every run produced 27 records and passed the wire suite's lifecycle and
idle cases. Variant definitions and measurement limitations accompany the records.
Zero-test filter attempts were excluded. An early Debug/Paramiko baseline timed out
on remote64 EOF; an initial OpenSSH smoke attempted the unsupported delayed-listener
case. Neither is presented as a successful performance measurement.

### Final measurements

Medians of five runs; throughput is useful MiB/s **per direction**. CPU includes
the entire app/test host and clients, excluding the server. Comparisons are against
the same OpenSSH baseline, not the earlier Paramiko results.

| Workload | Baseline MiB/s | Final MiB/s | Baseline CPU ms/total MiB | Final CPU ms/total MiB |
|---|---:|---:|---:|---:|
| Local, 64 duplex streams | 159.2 | 176.1 | 2.82 | 2.70 |
| Dynamic, 64 duplex streams | 159.6 | 178.2 | 2.84 | 2.68 |
| Remote, 64 duplex streams | 159.5 | 158.6 | 3.00 | 2.96 |
| Mixed, direct | 163.5 | 175.4 | 3.15 | 3.06 |
| Mixed, one jump | 94.6 | 175.7 | 8.09 | 5.78 |
| Mixed, two jumps | 94.4 | 164.1 | 11.82 | 8.40 |

| Mixed workload | Ready p95 ms, baseline → final | Small request p95 ms, baseline → final |
|---|---:|---:|
| Direct | 205.3 → 213.9 | 18.1 → 16.5 |
| One jump | 570.8 → 330.8 | 16.9 → 5.1 |
| Two jumps | 470.3 → 295.2 | 19.2 → 11.7 |

The robust result is improved jump throughput with less CPU per transferred byte.
Direct throughput changes are smaller. Remote64 throughput is essentially flat;
its readiness p95 increased from 11.5 to 14.1 ms. The pre-I/O accept sweep prevents
systematic deferral behind bulk I/O but does not establish an across-the-board
latency win. Local64/dynamic64 readiness remains substantial under sustained load
(1,873/1,721 ms final medians versus 2,238/2,442 ms baseline).

The earlier five-run conservative candidate gave 165.8/148.4 MiB/s for one/two-jump
mixed traffic. Three alternating old/new checks reproduced the jump improvement:
93.8 → 173.3 and 89.2 → 156.1 MiB/s; CPU 8.11 → 5.82 and 12.22 → 9.05 ms/total MiB.
Two-jump small-request p95 was 15.8 → 10.1 ms. Direct local/dynamic/remote64 throughput
was 153.0 → 167.8, 157.9 → 173.0 and 149.5 → 152.4 MiB/s. This comparison predates
only the extra remote-accept sweep; its remote readiness p95 was 11.1 → 18.4 ms,
which motivated that adjustment. Chronological/environmental variation is visible;
the final sweep alone must not be credited with the later throughput differences.

### Why 4 MiB was not selected

A 4 MiB receive allowance improved some direct admission and throughput results,
but did not materially improve jumps until the socketpair bottleneck was addressed.
It also raised whole-process peak RSS: the median per-run peak was 505 MiB for the
4 MiB receive variant versus 262 MiB baseline. Even the 1 MiB candidate had a
464 MiB median peak. The 256 KiB conservative candidate was 261 MiB, with the
alternating baseline/candidate maxima 262/262 MiB. Final-run peaks were 228–243 MiB;
these include the app, test clients, library buffers and prior cases, and do not
prove a transport-only memory reduction.

Increasing socketpair buffers further from 256 KiB to 4 MiB offered no consistent
benefit: at the same 4 MiB receive allowance, the 4 MiB socketpair candidate reached
152.8/140.8 MiB/s in one/two-jump mixed traffic, below the chosen smaller-buffer
candidates. Higher read-ahead and kernel capacity are therefore not shipped merely
because the operating system accepts them. The current choice favors bounded
memory and the repeatable jump-path gain. iOS uses a smaller 64 KiB socketpair
request; simulator correctness does not establish physical-device speed or memory.

Single-stream transfers last only around 40 ms and are noisy. This is encrypted
loopback data, not a WAN/physical-iOS capacity claim. No dependency, cipher policy,
SSH session-sharing policy or authentication behavior was changed.

### Reproduce the OpenSSH fixture

```sh
python3 Scripts/ssh-forwarding-openssh-fixture.py --metadata /tmp/termind-openssh.json
```

Use `/tmp/termind-openssh.json` as `TEST_RUNNER_TERMIND_SSH_FIXTURE` with the existing
wire-suite command above. Keep the metadata private: it contains the temporary
client key and is created mode 0600. Stop the fixture normally to remove it and its
temporary keys. Release runs need the same isolated-harness adjustments documented
above. Both forwarding test sources are now also compiled by TFITests so the shared
pump and fixture can be exercised on iOS Simulator.
