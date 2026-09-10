# Sandcube — runtime, image, file and process milestones

A minimal Crystal API calling a Go adapter over a private Unix socket. The adapter uses the official containerd v2 SDK and **requires gVisor** (`io.containerd.runsc.v1`). There is no runc fallback.

Implemented: binary file APIs, safe directory operations, detached execution with process status/logs/cancellation ([Phase 3 API and limits](docs/files-processes.md)); Dockerfile image builds with BuildKit, PostgreSQL image metadata, OCI import/inspection/deletion, and sandbox creation from reusable image IDs; plus create from an existing OCI image, start, stop, restart, inspect, synchronous exec, and delete. See [image setup, API, and testing](docs/images.md). Stop deletes only the task; start reuses the same container and writable snapshot. Runtime metadata lives in containerd and survives API/adapter restarts.

## Prerequisites

Tested on this VPS with containerd 2.2.3, gVisor release-20260622.0, Crystal 1.19.1, and Go 1.27.1.

Linux VPS with root access, containerd 2.2+, gVisor (runsc and containerd-shim-runsc-v1 on containerd's PATH), overlayfs snapshotter, cgroups, Crystal 1.19+, Go 1.25+, and Python 3 for acceptance tests. Allow enough RAM for compilation; the Makefile limits Crystal compilation to one thread.

Install gVisor using the [official installation guide](https://gvisor.dev/docs/user_guide/install/). Keep the `gvisor-bin` directory beside `runsc` on releases that include it. See the [containerd quick start](https://gvisor.dev/docs/user_guide/containerd/quick_start/). The included `infra/gvisor/runsc.toml` sets `overlay2=none`: gVisor must write into containerd’s snapshot instead of its ephemeral overlay (see [filesystem configuration](https://gvisor.dev/docs/user_guide/filesystem/)). The adapter passes this config directly to the shim and sets explicit sandbox identity annotations, required for correct init stream handling. No containerd configuration change is needed when its shim binary is discoverable on PATH. Installing the runtime does not require restarting existing containers.

For this workspace, the Go toolchain is available at `.tools/go/bin/go` (ignored generated tooling). Use `make build GO="$PWD/.tools/go/bin/go"` if Go is not on your PATH.

## Start the dedicated runtime

Run this in its own terminal before starting the API or integration tests:

```sh
sudo containerd --config "$PWD/infra/containerd/config.toml"
```

This uses `/var/lib/sandcube-containerd` and `/run/sandcube-containerd`, independently of Docker. The adapter defaults to this instance. To use a different existing instance, pass `-containerd /path/to/containerd.sock`; for tests set `SANDCUBE_CONTAINERD` to that same path.

## Build and test

```sh
make build
make test

# Root required; uses a dedicated namespace, never Docker's namespace.
sudo ctr --address /run/sandcube-containerd/containerd.sock -n sandcube-test images pull --platform linux/amd64 docker.io/library/busybox:1.37.0
sudo python3 scripts/integration.py
```

`make test` runs Go tests with the race detector, Go vet, and Crystal specs. The integration script starts both services on temporary local endpoints and verifies authentication, socket permissions, actual gVisor execution, OCI security settings and actual cgroup limits, failed-start rollback, independent writable filesystems, stdout/stderr and exit codes, working directory/environment, timeout, output limits, stopped exec rejection, filesystem persistence through service restarts, concurrent/repeated starts, removal of previous workload processes, restart, and idempotent deletion. It checks containerd directly for snapshot removal and preservation of the original image. It cleans up the sandbox IDs it creates and terminates its services, leaving the reusable test image cached. Reserve `sandcube-test` for these tests; the harness takes an exclusive lock to prevent concurrent runs. See [verification results](docs/testing.md).

## Run locally

```sh
sudo install -d -m 0700 /run/sandcube
sudo ctr --address /run/sandcube-containerd/containerd.sock -n sandcube images pull --platform linux/amd64 docker.io/library/busybox:1.37.0
sudo install -d -m 0755 /etc/sandcube
sudo install -m 0644 infra/gvisor/runsc.toml /etc/sandcube/runsc.toml
sudo ./bin/containerd-runtime
```

In another terminal, set `SANDCUBE_API_KEY` to a random secret of at least 32 bytes, then run `./bin/sandcube` as the same user as the adapter (root in this initial setup). It listens on `127.0.0.1:8080` by default. The adapter creates a mode-0600 socket and refuses to replace an existing path. After an unclean adapter exit, verify no adapter is running before removing a stale socket.

Configuration:

| Component | Setting | Default |
| --- | --- | --- |
| Crystal | `SANDCUBE_API_KEY` | Required, at least 32 bytes |
| Crystal | `SANDCUBE_RUNTIME_SOCKET` | `/run/sandcube/runtime.sock` |
| Crystal | `SANDCUBE_HOST` | `127.0.0.1` |
| Crystal | `SANDCUBE_PORT` | `8080` |
| Adapter | `-socket` | `/run/sandcube/runtime.sock` |
| Adapter | `-containerd` | `/run/sandcube-containerd/containerd.sock` |
| Adapter | `-runsc-config` | `/etc/sandcube/runsc.toml` |
| Adapter | `-namespace` | `sandcube` |

Run one API and one adapter per namespace. Both serialize lifecycle operations; exec does not block stop/delete. Keep the API on loopback unless placed behind an authenticated TLS endpoint.

## API example

All endpoints, including `/health`, require `Authorization: Bearer $SANDCUBE_API_KEY`.

```sh
curl -sS http://127.0.0.1:8080/v1/sandboxes \
  -H "Authorization: Bearer $SANDCUBE_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"image":"docker.io/library/busybox:1.37.0","command":["/bin/sleep","infinity"],"cpu":1,"memory_mb":256,"pids":128}'
```

The response contains a generated `sbx_...` ID, `status`, and `snapshot_key`. Save that ID as `SANDBOX_ID`.

```sh
curl -sS "http://127.0.0.1:8080/v1/sandboxes/$SANDBOX_ID/exec" \
  -H "Authorization: Bearer $SANDCUBE_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"command":["/bin/sh","-c","echo hello > /proof"],"timeout_seconds":30}'
```

| Method | Path | Behavior |
| --- | --- | --- |
| GET | `/health` | Checks adapter/containerd connectivity |
| POST | `/v1/sandboxes` | Creates and starts; rolls back failed start |
| GET | `/v1/sandboxes/:id` | Reads actual runtime state |
| POST | `/v1/sandboxes/:id/exec` | Returns `stdout`, `stderr`, `exit_code`, `timed_out`, `truncated` |
| POST | `/v1/sandboxes/:id/stop` | Stops all processes, retains writable snapshot |
| POST | `/v1/sandboxes/:id/start` | Starts configured environment command on retained snapshot |
| POST | `/v1/sandboxes/:id/restart` | Stop then start under a lifecycle lock |
| DELETE | `/v1/sandboxes/:id` | Removes container and writable snapshot, retains image |

Exec accepts `command` (argv), optional `cwd` (absolute path), `env` (string map), and `timeout_seconds` (1–3600, default 30). A nonzero process exit is a successful API response with its exit code. Output is capped at 1 MiB per stream and continues to be drained after that limit. The JSON command request limit is 64 KiB; file transfers use a separate 16 MiB limit.

The create `command` must be a long-running environment process available in the image; the platform assumes no shell or utilities. It is started again on each start, while previously executed workload processes are not restored. The example uses BusyBox's `sleep infinity` solely for the milestone fixture.

## Scope

This implements Phases 1–4, not the full V1 service. Sandboxes have isolated network namespaces **without outbound connectivity**. CPU, memory and process limits are configured; disk quotas, aggregate VPS capacity checks and streaming/TTY remain future work. PostgreSQL enables durable sandbox metadata, lifecycle reconciliation, idempotency and TTL; the adapter preserves process history and logs across restarts. Exec timeout kills the requested process; it does not yet provide a process-tree cancellation API. Do not expose this milestone as a public multi-tenant service.

## Phase 4 reliability

[Durable recovery, idempotency, TTL and metrics](docs/reliability.md) are enabled with `DATABASE_URL`. Process history and bounded stdout/stderr capture survive API/adapter crashes. Run `make integration-reliability` with a dedicated `TEST_DATABASE_URL` and test runtime to exercise real SIGKILL recovery.
