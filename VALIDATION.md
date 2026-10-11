# Validation scope

This is an experimental implementation, not a security certification.

Validated in the original Windows deployment:

- Go unit/integration tests and go vet.
- Independent client netstack → gateway → mock SOCKS → generated packets: TCP, UDP, DNS rewriting, TCP retransmission, 9KB fragmented UDP at MTU1280, flow limits/expiry, and bounded close.
- Official WinDivert DLL checksum helper for IPv4 fragments, without opening a driver handle in the tests.
- Official runtime hash checks and valid Windows driver Authenticode signature.
- Actual driver capture smoke, guard/proxy readiness and unchanged Windows default routes.
- Existing Mihomo SOCKS TCP DNS, UDP DNS and HTTPS probe.
- iPhone cellular IPv4 HTTPS exit matched Mihomo; user confirmed video playback.
- On that cellular connection, IPv6-only endpoint worked with Default Route OFF and failed with ON. This is not IPv6 proxy support or a persistent IPv6 blocking guarantee.
- Native PowerShell5.1 lifecycle tests; actual SYSTEM task startup, High process priority and proxy restart while the independent guard remained alive.
- Supervisor fixtures: fresh startup, unavailable upstream with guard retained, replacement guard before retiring the old proxy, and previous-boot PID reuse avoidance.

Desktop/mobile validation for v0.3.0:

- Eleven desktop model checks, including stale heartbeat, partial JSON log tails, path boundaries and rate reset on process changes.
- Mobile server tests cover token/IP/Host/Origin boundaries, restricted endpoints, selector membership, duplicate commands, durable command records, readback confirmation and unconfirmed results.
- A 390×844 mobile browser viewport passed pairing, remembered access, search, confirmation cancellation and no horizontal overflow, with no page-script errors.
- The real local named-pipe controller was exercised by reselecting the existing node. The response and desktop audit agreed; the desktop UI displayed the confirmed command.
- The user subsequently confirmed that a physical iPhone could control proxy selection successfully. This is user-reported acceptance, not a comprehensive test across iOS versions.
- Mobile and tray logon tasks were installed with limited user privileges; the existing gateway proxy and guard remained running during installation.

Control validation for v0.3.1 (2026-10-11):

- Mobile controller tests pass using in-memory HTTP transport. They cover rule-mode defaults and nested paths, direct mode, unavailable rules, fixed-URL node delays and escaped names, invalid requests, concurrent delay/read/selection, final readback reconciliation, applied writes with failed HTTP responses, idempotency and cancelled refreshes.
- Full `go test ./...` and `go vet ./...` pass. Desktop's eleven model checks and both control builds pass. Bilingual command parity and local documentation links pass.
- A rendered 390×844 mobile viewport with mocked data passes latency labels and sorting, preferred/manual group preservation, exact-name readback, old-poll cancellation and stale response rejection, disconnected controls and no horizontal overflow, with no page-script errors.
- The deployed named-pipe controller returned real delay measurements for three existing nodes. A command reselecting the current node was confirmed by controller readback and the desktop audit, without choosing a different node for this diagnostic.
- The user confirmed that a physical iPhone displays node delays and updates Clash selections. The latest phone command's confirmed target agreed with the current group selection. This is acceptance on one device, not coverage across all iOS or Clash versions.
- The control updater installed v0.3.1 and verified a fresh online heartbeat. Configuration, pairing QR, gateway binary and runner hashes remained unchanged; task XML was preserved, and the original forwarding run stayed ready. Its initial readiness failure exercised restoration of the previous control binaries before the UTF-8 reader fix.
- Eight isolated updater checks pass in PowerShell 5.1 and 7, covering hash-checked copying, changed-source rejection, Chinese UTF-8 status, nanosecond timestamps, heartbeat rejection and reused-PID refusal. The test helper never changes installed files, tasks or processes.

Stability validation for v0.3.2 (2026-10-11):

- Full Go tests and vet pass, including separate TCP/UDP expiry, activity/expiry races, half-close replies, legacy configuration defaults, byte counts and connection boundaries. The optional `ZEROBRIDGE_LONG_TCP_TEST=1` test keeps a real packet-to-SOCKS TCP connection idle for 125 seconds with the legacy 120-second UDP limit; the same stream then echoes successfully with no errors or TCP idle expiration.
- Runtime tests cover interface loss and restoration with a different index, no stale/default return sends, unchanged guard identity requirements, bounded SOCKS-only DNS probes, failure/recovery hysteresis and Windows atomic heartbeat replacement. These simulate interface changes; they do not recreate the deployed physical adapter.
- PowerShell 5.1 and 7 pass 26 supervisor health checks and 46 gateway updater checks, including PID/start/configuration binding, proof roles, freshness, typed UTC/offset dates after JSON parsing and a forced readiness failure that restores both old files before restarting the previous version. The fixtures never operate installed tasks or processes.
- UDP loopback benchmarks with 1200-byte datagrams reduce steady-state receive allocations from 1 allocation / 65,603 bytes per operation to 0, and send from 2 allocations / 1,289 bytes to 0. This measures local processing, not cellular or Internet throughput.
- Fourteen desktop model checks pass, including byte-based Mbps, counter-reset protection and degraded-state chart pause. Both control programs and the gateway build successfully.
- A rendered 390x844 phone mock verifies latency/group/selection behavior and online/pageshow/visibility recovery. Stale state GETs are cancelled; pending selection/delay POSTs are not aborted or replayed. Pairing and manual group selection persist, offline controls disable, and there are no page-script errors or horizontal overflow.
- The deployed gateway, mobile control and desktop report v0.3.2. Fresh owned health, SYSTEM boot task, High gateway child priority and both user tasks were checked. Configuration, pairing QR and task settings were preserved; WinNAT remained absent. The user confirmed cellular proxy access/video on initial connection and again after about three minutes idle on a physical iPhone.
- Subsequent live traffic reached the configured 256 shared TCP/UDP flow limit and increased `flow_limit_rejections` to 93; this counts rejected attempts, including retries, not distinct applications or network packet loss. With available memory checked, only the installed configuration was tuned to 512. Fresh owned health, matching configuration proofs, High priorities, the boot task and unchanged pairing were verified after restart. The repository default remains 256; this capacity adjustment does not establish an Internet speed gain.

Still not established:

- Long-term reliability, independent security audit, sustained adversarial/resource-exhaustion testing.
- Every client UDP application or actual client UDP large-packet path. Flow counts and TCP-capable video playback alone do not prove UDP replies.
- Actual Windows reboot acceptance; the boot task was manually invoked and its trigger verified.
- Persistent fail-closed behavior across both process failures, driver failure, startup gaps, reboot or IPv6 routing changes.
- General installation across arbitrary NAT, interfaces, proxy configurations or multi-user hosts.

Operational logs, machine identities, live IP addresses and original NAT backups are intentionally excluded. Sanitized test fixtures use example private addresses. Publication checks rebuild and test the source copy without changing the running installation.
