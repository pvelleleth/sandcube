# Runtime and image milestone verification

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

The original checks above prove the first two milestones; Phase 3 coverage is recorded below. They do not certify the full V1 service: disk quotas, capacity accounting, outbound networking and streaming/TTY remain outside these milestones. Phase 4 recovery and cleanup are covered by the separate suite described below. Timeout currently targets the requested process, not a process tree. No public endpoint was deployed.


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
