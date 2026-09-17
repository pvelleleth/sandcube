# Runtime and image milestone verification

## CLI and installation milestone

The CLI suite covers config permissions and secret round trips, invalid input, exact XFS mount/quota checks, nonempty-storage rejection, binary payload checksums and corruption, symlink/path-traversal rejection, private daemon configuration, readiness deadlines, early process exit, unexpected crashes, reverse-order shutdown, SIGKILL escalation, real SIGINT/SIGTERM during startup, and occupied/stale sockets.

`make test` also runs eight installer/release tests with real RSA signing, verification and hashing against a simulated host. These exercise amd64/arm64 selection, optional dependencies/systemd, bad signatures and artifact checksums, and release-script output. They do not install packages or modify the host. `make test-package` verifies the actual embedded bytes against both built executables and exercises commands from an unrelated directory without database configuration.

Database specs run automatically against temporary SQLite files; no database service or credentials are required. They exercise lifecycle recovery, image reservations, TTL, admission races, and database close/reopen persistence. For real host acceptance, install runtime dependencies and use a disposable Linux host without an installed Sandcube systemd unit:

```sh
sudo -E make integration-cli
```

The harness uses the packaged CLI to provision a new 768 MiB XFS image and SQLite database, then checks doctor, readiness, duplicate-supervisor rejection, unauthenticated API calls, automatic image pulling, persistent sandbox execution, Ctrl-C shutdown/restart, adapter-crash propagation, SIGTERM shutdown, and managed remount. State and logs are retained under `.cli-acceptance-*` for inspection. Set `SANDCUBE_TEST_STORAGE` to an empty XFS/prjquota mount to exercise custom storage instead. Manual-process acceptance suites launch `bin/sandcube-api` with fresh temporary data directories.

Verified on 2026-09-17: 81 Crystal examples passed using local SQLite, including close/reopen persistence, metadata access during runtime waits, and legacy-config rejection. Go race tests and vet passed. The packaged CLI acceptance passed with automatically provisioned storage and no API credentials or database URL. The real containerd/gVisor reliability suite passed all eight SIGKILL-before/after lifecycle cases, duplicate API rejection, concurrent idempotent creates, process-history/log recovery, file persistence, TTL, metrics and orphan cleanup. Installer and packaged-binary tests passed. Dependency installation across every supported distribution and static arm64 release execution remain release-environment checks.

## Historical verification before the SQLite conversion

The results and commands below describe earlier PostgreSQL-based versions, not current setup requirements.

Verified locally on 2026-09-11: all 78 Crystal examples passed against an isolated local PostgreSQL database, with no pending examples; Go race tests and vet passed; all eight installer/release tests and both packaged-binary tests passed. Static amd64 Crystal launcher/API compilation and static Go adapter compilation were also exercised.

The real packaged-CLI acceptance passed using a newly created disposable 1 GiB XFS image mounted with `prjquota`, a fresh local PostgreSQL database, containerd 2.2.3 and the host's gVisor release-20260622.0. This verified actual startup, sandbox execution, file persistence through supervisor restart, duplicate-start rejection, adapter-crash propagation, and SIGINT/SIGTERM shutdown. The temporary filesystem, database, role and runtime directory were removed afterward. Dependency package installation on each supported distro, execution with the installer's newer pinned gVisor release, arm64 execution, and publication with a production signing key remain release-environment checks.

## Earlier runtime verification

Verified on 2026-09-10 on the target Linux VPS using containerd 2.2.3, gVisor release-20260622.0, Crystal 1.19.1, Go 1.27.1, PostgreSQL 16.15 and BuildKit 0.33.0. Tests used the dedicated containerd instance configured by `infra/containerd/config.toml`.

## Commands

```sh
make build GO="$PWD/.tools/go/bin/go"
make test GO="$PWD/.tools/go/bin/go"
sudo python3 scripts/integration.py
```

The Go suite passes with the race detector; `go vet` passes. All 35 Crystal specs pass, including the real PostgreSQL lifecycle/race tests using `DATABASE_URL` (or an explicit `TEST_DATABASE_URL` override). The actual gVisor acceptance test passes through the Crystal HTTP API and Go Unix-socket adapter.

## Acceptance checks

- API key rejection and mode-0600 Unix socket.
- Missing startup executable returns an error and leaves no container or writable snapshot; missing images are rejected.
- Runtime identity is gVisor, confirmed both through containerd metadata and the sandbox's `dmesg`.
- Empty capability set, no-new-privileges and private network namespace.
- Kernel cgroup CPU, memory and process limits match the requested configuration.
- No host service socket or workspace mounted into the sandbox; no outbound routes.
- stdout, stderr, nonzero exit code, environment overrides and working directory.
- Timeout kills the requested process; excess output is drained with bounded capture.
- A second sandbox cannot see the first sandbox's changes.
- Stop preserves container metadata and the writable snapshot; exec while stopped is rejected.
- Restarting both services while the sandbox is stopped does not lose its identity or files.
- Concurrent/repeated start, repeated stop and restart succeed.
- Exact file content survives stop/start and restart; old workload processes are gone.
- Repeated deletion removes the container and writable snapshot, leaves the original image, and leaves the second sandbox operational.

## Regression findings addressed

The gVisor shim requires explicit `io.kubernetes.cri.container-type=sandbox` and sandbox ID annotations for correct init stream handling. Omitting them can leave `runsc create` waiting on an inherited output pipe. The acceptance test asserts these annotations and runs real commands.

The gVisor configuration uses `overlay2=none`, so writes reach containerd's writable snapshot instead of an ephemeral gVisor overlay. The acceptance test compares exact file contents after task and service recreation.

A failed start never produces a normal process-exit event. Cleanup deletes non-running tasks through the official containerd task service instead of waiting for a nonexistent event. The missing-executable regression checks that both container and snapshot are rolled back.

## Scope of evidence

The original checks above prove the first two milestones; Phase 3 coverage is recorded below. They do not certify the full V1 service. Phase 5 below adds disk quotas, capacity accounting and outbound networking; streaming/TTY remain outside the implemented milestones. Phase 4 recovery and cleanup are covered by the separate suite described below. Timeout currently targets the requested process, not a process tree. No public endpoint was deployed.


## Phase 2 image acceptance

Run with a dedicated PostgreSQL test database and a running isolated BuildKit daemon:

```sh
TEST_DATABASE_URL=postgres://... make build test GO="$PWD/.tools/go/bin/go"
TEST_DATABASE_URL=postgres://... \
SANDCUBE_BUILDCTL="$PWD/.tools/buildkit/bin/buildctl" \
SANDCUBE_BUILDKIT_ADDRESS=unix:///run/sandcube-buildkit-test/buildkitd.sock \
python3 scripts/integration_images.py
```

Verified through the real Crystal API, PostgreSQL, BuildKit, containerd and gVisor:

- Multipart Dockerfile + ustar tar.gz + build arguments return 202/BUILDING and become READY with an OCI digest.
- Dockerfile installs curl, copies a file, and sets ENV and WORKDIR.
- Restarting the API preserves image metadata; setting buildctl to a nonexistent executable still permits creating two sandboxes from that image ID.
- Both sandboxes contain curl and the original file; modifying one leaves the other unchanged. The modified file survives stop/start.
- Referenced images cannot be deleted, including when a sandbox is stopped. The adapter independently rejects deletion when called directly over its Unix socket.
- A failed RUN yields ERROR with bounded diagnostic text, no remaining build directory or runtime image reference, and cannot be used for sandbox creation.
- Traversal, absolute paths, symbolic links and hard links are rejected before building and leave no temporary directory.
- Failed-start rollback releases image reservations after runtime cleanup. Deleting the final sandbox permits idempotent image deletion and removes the containerd image reference and writable snapshots.

Additional unit/database tests cover argument injection resistance and environment clearing, build timeout/log limits, gzip checksum/truncation, duplicate entries, special/extended tar types, archive expansion/entry limits, malformed uploads, concurrent image reservation/deletion, failed rollback reservation retention, deletion retries, and interrupted-build recovery. Go tests run with the race detector and `go vet`.

BuildKit and PostgreSQL are test prerequisites, not mocked in the acceptance suite. PostgreSQL specs use `TEST_DATABASE_URL`, falling back to `DATABASE_URL`; they report a pending test only when neither is set. Each example creates and cleans up a unique schema, with the search path applied to every pooled connection so recovery tests cannot update existing application rows. The role needs CREATE SCHEMA permission. The BuildKit acceptance script still requires a dedicated test database. No production endpoint was deployed.


## Phase 3 file and process acceptance

The runtime acceptance harness now includes [Phase 3 checks and API limits](files-processes.md). It tests binary file transfer, executable uploads, live file replacement, oversized request rejection, traversal and symlink escapes, detached execution across API reconnect, captured logs and generated artifacts, concurrent exit codes, output bounds, cancellation, stopped file access, persistence, and stop/delete with active processes. Unit tests add concurrent symlink swapping, special-file rejection, hardlink-safe replacement, modes, and route validation.

Verified on 2026-09-10: the build succeeded; Go tests passed with `-race` and `go vet` passed; Crystal reported 35 examples, zero failures/errors, and zero pending tests after running against `DATABASE_URL` with isolated test schemas. Schema cleanup was verified. The complete real containerd/gVisor runtime acceptance suite passed, including the executable upload → detached launch → public API restart/reconnect → logs/artifact retrieval → cancellation workflow. The test namespace had no remaining containers after cleanup.

## Phase 4 reliability acceptance

Verified on 2026-09-10 with a dedicated local PostgreSQL database and the real containerd/gVisor/BuildKit stack. `make test` passes: 49 Crystal examples, zero failures/errors/pending; Go tests pass with `-race`, and `go vet` passes. The existing runtime/file/process and Dockerfile/image acceptance suites also pass.

The new `scripts/integration_reliability.py` suite passes these checks:

- SIGKILL both API and adapter immediately before and after create/start/stop/delete runtime calls, with committed PostgreSQL intent and missing HTTP responses.
- Restart on the stale Unix socket, reconcile, and safely replay the original idempotency key; conflicting reuse returns 409.
- Concurrent identical creates through two API processes produce one sandbox.
- Completed process history survives restart; processes that exit while both services are down retain their real exit codes and separate stdout/stderr output.
- Live process recovery, including a journal record still marked `starting`, returns the same running process without launching it again.
- Lost exec responses replay without repeating file-modifying command side effects.
- Uploaded/generated files persist across API/adapter crashes and stop/start.
- Running and stopped TTL expiry removes sandbox resources while preserving reusable images.
- Unknown managed containers and labelled orphan snapshots are removed; unlabelled snapshots remain.
- Authenticated metrics include real CPU/memory/snapshot usage and cleanup outcomes.

Database fault tests additionally cover failed create compensation and error replay, restart's durable stop/start boundary, cleanup failure with retained image reservations, inventory outages, missing containers, and key conflicts. Go tests cover atomic history recovery, corrupt metadata rejection, bounded stdout/stderr capture, orphan setup-directory cleanup, and retrying runtime process-record deletion while retaining history.

The test namespace was left with no containers or sandbox snapshots; reusable base image content remains. All isolated PostgreSQL spec schemas were removed. See [reliability operations and limits](reliability.md) for deployment configuration, retention, and the distinction between adapter crashes and host/shim failure.


## Phase 5 resource and network acceptance

Verified on 2026-09-10 using a disposable 1 GiB XFS filesystem mounted with `prjquota`, a separate containerd instance, the real gVisor runtime, and a dedicated local PostgreSQL test database. The existing host filesystem was not reformatted. All 58 Crystal examples pass with zero failures, errors or pending examples. Go tests pass with the race detector, including the real kernel project-quota test, and `go vet` passes.

`scripts/integration_resources.py` passes the Phase 4 recovery harness and these additional checks:

- Concurrent real API creates respect capacity; stop releases compute while preserving disk, and a competing start is rejected until capacity is freed.
- Public DNS and HTTPS package-index downloads work before and after API/adapter crashes.
- Host private/public addresses, gateway services, metadata addresses, private networks, peer sandboxes, rebound hostnames and IPv6 destinations are blocked. Firewall packet counters confirm the drops.
- Guest writes and stopped file API writes cannot exceed the quota. Stop/start and crashes retain enforcement; deletion verifies physical blocks/inodes are reclaimed.
- Stop removes conntrack entries before its address is reusable.
- CPU usage under load stays within the configured cgroup budget. Memory swap is disabled, group OOM killing terminates the task, and reconciliation releases compute after actual OOM.
- Quota-bearing orphan snapshots are reclaimed after metadata loss; disk reservations remain conservative until deletion completes.
- SIGKILL immediately after firewall creation, namespace creation, veth creation, address assignment and link activation recovers safely. SIGKILL during conntrack and firewall deletion also converges.
- Successful completion leaves no sandbox containers, network namespaces, firewall tables or resource ownership journals for the run.

Database tests independently exhaust CPU, memory and disk, race starts against creates across coordinators, retain reservations through lost responses and failed cleanup, handle stopped expiration, reject unaccounted runtime inventory, and reject conflicting persisted host budgets. Additional Go tests reject corrupt ownership journals without discarding them.

See [deployment prerequisites and migration](resources-networking.md). Tests kill API/adapter processes and exercise real kernel resources; they do not reboot the host or promise to restore running processes across a host reboot.

The existing runtime/file/process and Dockerfile/image acceptance suites also pass with the new quotas and networking. Final checks found zero live test sandboxes, zero CPU/memory/disk reservations and zero isolated spec schemas. The disposable runtime, BuildKit daemon, test databases, XFS mount and temporary forwarding allowances were cleaned up.
