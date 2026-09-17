# Sandcube — sandbox service

A Crystal CLI that supervises a private containerd instance, a Go runtime adapter, and the Crystal HTTP API. The adapter uses the official containerd v2 SDK and **requires gVisor** (`io.containerd.runsc.v1`). There is no runc fallback for sandboxes.

Implemented: binary file APIs, safe directory operations, detached execution with process status/logs/cancellation ([Phase 3 API and limits](docs/files-processes.md)); Dockerfile image builds with BuildKit, SQLite image metadata, OCI import/inspection/deletion, and sandbox creation from reusable image IDs; plus create from an existing OCI image, start, stop, restart, inspect, synchronous exec, and delete. See [image setup, API, and testing](docs/images.md). Stop deletes only the task; start reuses the same container and writable snapshot. Runtime metadata lives in containerd and survives API/adapter restarts.

## Install and start

Once a signed release has been published, installation and startup are:

```sh
curl -fsSL https://github.com/pvelleleth/sandcube/releases/latest/download/install.sh | sh
sudo sandcube init
sudo sandcube serve
```

`init` provisions local storage, creates SQLite metadata, and saves the host configuration. No database server, database account, API key, or manually prepared filesystem is needed. On a typical VPS it preallocates an XFS disk image using 75% of free disk space and mounts it with project quotas. It never formats an existing block device. `serve` restores the mount after reboot and starts the API and runtime.

`sandcube doctor` reports host prerequisites. `init` chooses capacity budgets that reserve one CPU (when available), 25% of RAM, and 25% of the managed filesystem for overhead. Optional overrides are `--storage-size-mb`, `--capacity-cpu`, `--capacity-memory-mb`, and `--capacity-disk-mb`. Advanced deployments can use an existing empty XFS/prjquota mount with `--storage /mnt/sandcube`. Capacity budgets are persisted in SQLite and must agree on subsequent starts.

The signed Linux amd64/arm64 executable contains both internal binaries. `serve` verifies and extracts them, checks readiness in dependency order, forwards child stdout/stderr, and stops children in reverse order on Ctrl-C, SIGTERM, startup failure or a child exit. An unexpected exit fails the whole service; systemd can restart it. It never attaches to a host's Docker/containerd instance.

For reboot startup, install with `sh -s -- --systemd`, then run `init` and `sudo systemctl start sandcube`. Dockerfile image builds are enabled by default through BuildKit/CNI. Public OCI images are pulled and unpacked automatically on first use; use a fully qualified image reference such as `docker.io/library/busybox:1.37.0`.

See [installation, configuration, upgrades and signed releases](docs/installation.md) for the complete layout and publishing instructions. This repository includes the release pipeline; a release signing key must be configured before publishing the first installable release.

## Development prerequisites

Tested on this VPS with containerd 2.2.3, gVisor release-20260622.0, Crystal 1.19.1, and Go 1.27.1.

Linux VPS with root access, SQLite development libraries, XFS snapshot storage mounted with `prjquota`, `iproute2`, `nftables`, `conntrack`, IPv4 forwarding, containerd 2.2+, gVisor (runsc and containerd-shim-runsc-v1 on containerd's PATH), overlayfs snapshotter, cgroup v2, Crystal 1.19+, Go 1.25+, and Python 3 for acceptance tests. Allow enough RAM for compilation; the Makefile limits Crystal compilation to one thread.

Install gVisor using the [official installation guide](https://gvisor.dev/docs/user_guide/install/). Keep the `gvisor-bin` directory beside `runsc` on releases that include it. See the [containerd quick start](https://gvisor.dev/docs/user_guide/containerd/quick_start/). The included `infra/gvisor/runsc.toml` sets `overlay2=none`: gVisor must write into containerd’s snapshot instead of its ephemeral overlay (see [filesystem configuration](https://gvisor.dev/docs/user_guide/filesystem/)). The adapter passes this config directly to the shim and sets explicit sandbox identity annotations, required for correct init stream handling. No containerd configuration change is needed when its shim binary is discoverable on PATH. Installing the runtime does not require restarting existing containers.

For this workspace, the Go toolchain is available at `.tools/go/bin/go` (ignored generated tooling). Use `make build GO="$PWD/.tools/go/bin/go"` if Go is not on your PATH.

See [Phase 5 setup and migration requirements](docs/resources-networking.md) before starting the runtime. Quotas fail closed on unsupported storage.

## Start a development runtime manually

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
sudo -E python3 scripts/integration.py
```

`make test` runs Go tests with the race detector, Go vet, Crystal specs (including CLI/supervisor tests), and signed-installer tests against a simulated host. `make test-package` builds the single executable and verifies its embedded binaries and CLI behavior. The existing integration suites use `bin/sandcube-api` directly and check the real runtime; reserve `sandcube-test` for those tests. See [verification results](docs/testing.md).

## Run locally

```sh
sudo install -d -m 0700 /run/sandcube
sudo ctr --address /run/sandcube-containerd/containerd.sock -n sandcube images pull --platform linux/amd64 docker.io/library/busybox:1.37.0
sudo install -d -m 0755 /etc/sandcube
sudo install -m 0644 infra/gvisor/runsc.toml /etc/sandcube/runsc.toml
sudo ./bin/containerd-runtime
```

For manual development only, configure `SANDCUBE_DATA_DIR` and the three allocatable capacity budgets below, then run `./bin/sandcube-api` as the same user as the adapter. SQLite is created automatically in that directory. This standalone API loads `.env` from its working directory; existing environment variables take precedence. Under `sandcube serve`, it receives the saved configuration and does not load `.env`. The API listens on `127.0.0.1:7432` by default. The adapter creates a mode-0600 socket and safely recovers stale sockets using lifetime locks.

Configuration:

| Component | Setting | Default |
| --- | --- | --- |
| Crystal | `SANDCUBE_DATA_DIR` | `/var/lib/sandcube/data`; contains `sandcube.db` |
| Crystal | `SANDCUBE_CAPACITY_CPU` | Required; allocatable whole vCPUs |
| Crystal | `SANDCUBE_CAPACITY_MEMORY_MB` | Required; allocatable MiB |
| Crystal | `SANDCUBE_CAPACITY_DISK_MB` | Required; writable-storage MiB |
| Crystal | `SANDCUBE_RUNTIME_SOCKET` | `/run/sandcube/runtime.sock` |
| Crystal | `SANDCUBE_HOST` | `127.0.0.1` |
| Crystal | `SANDCUBE_PORT` | `7432` |
| Adapter | `-socket` | `/run/sandcube/runtime.sock` |
| Adapter | `-containerd` | `/run/sandcube-containerd/containerd.sock` |
| Adapter | `-runsc-config` | `/etc/sandcube/runsc.toml` |
| Adapter | `-namespace` | `sandcube` |

Run one API and one adapter per namespace. Both serialize lifecycle operations; exec does not block stop/delete. The API has no built-in authentication and is intended for a trusted backend. Use `sandcube init --host <private-IP>` to accept connections from that backend over your private network; the default is loopback.

## API example

No authorization headers are required.

```sh
curl -sS http://127.0.0.1:7432/v1/sandboxes \
  -H 'Content-Type: application/json' \
  -d '{"image":"docker.io/library/busybox:1.37.0","command":["/bin/sleep","infinity"],"cpu":1,"memory_mb":256,"disk_mb":1024,"pids":128}'
```

The response contains a generated `sbx_...` ID, `status`, and `snapshot_key`. Save that ID as `SANDBOX_ID`.

```sh
curl -sS "http://127.0.0.1:7432/v1/sandboxes/$SANDBOX_ID/exec" \
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

This implements Phases 1–5. Sandboxes have IPv4 internet access, public DNS, isolated network namespaces and enforced CPU/memory/disk limits. SQLite reserves host capacity before lifecycle operations; disk stays reserved while stopped. Streaming/TTY remain future work. SQLite enables durable sandbox metadata, lifecycle reconciliation, idempotency and TTL; the adapter preserves process history and logs across restarts. Exec timeout kills the requested process; it does not yet provide a process-tree cancellation API. Do not expose this milestone as a public multi-tenant service.

## Phase 4 reliability

[Durable recovery, idempotency, TTL and metrics](docs/reliability.md) are enabled automatically with local SQLite. Process history and bounded stdout/stderr capture survive API/adapter crashes. Run `make integration-reliability` with a dedicated test runtime to exercise real SIGKILL recovery.

## Phase 5 resource enforcement and networking

[Quota, capacity and networking operations](docs/resources-networking.md) describe required host setup, fail-closed behavior, crash recovery and migration from earlier phases. Run `make integration-resources` against a dedicated XFS-backed runtime and test database.
