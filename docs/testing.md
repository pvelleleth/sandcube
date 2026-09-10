# Runtime and image milestone verification

Verified on 2026-09-10 on the target Linux VPS using containerd 2.2.3, gVisor release-20260622.0, Crystal 1.19.1, Go 1.27.1, PostgreSQL 16.15 and BuildKit 0.33.0. Tests used the dedicated containerd instance configured by `infra/containerd/config.toml`.

## Commands

```sh
make build GO="$PWD/.tools/go/bin/go"
make test GO="$PWD/.tools/go/bin/go"
sudo python3 scripts/integration.py
```

The Go suite passes with the race detector; `go vet` passes. All 32 Crystal specs pass, including the real PostgreSQL lifecycle/race tests when `TEST_DATABASE_URL` is set. The actual gVisor acceptance test passes through the Crystal HTTP API and Go Unix-socket adapter.

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

These tests prove the first two milestones. They do not certify the full V1 service: disk quotas, capacity accounting, outbound networking, streaming/TTY, detached process management, TTL and crash reconciliation remain outside this milestone. Timeout currently targets the requested process, not a process tree. No public endpoint was deployed.


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

BuildKit and PostgreSQL are test prerequisites, not mocked in the acceptance suite. PostgreSQL specs explicitly report a pending test when `TEST_DATABASE_URL` is absent. No production endpoint was deployed.
