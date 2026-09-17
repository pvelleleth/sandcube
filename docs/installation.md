# Installation and operation

Sandcube releases target Linux amd64 and arm64. The release executable and its embedded Crystal API are statically linked; Crystal and Go are build-time requirements only. Sandboxes use gVisor. The BuildKit OCI worker uses runc and isolated CNI networking for image builds, matching the existing image-building model.

## Host preparation

The installer supports Debian/Ubuntu and Fedora/RHEL/Rocky/AlmaLinux/CentOS with apt or dnf. It installs networking utilities, XFS tools, containerd 2.2.3, gVisor release-20260907.0, BuildKit 0.33.0, CNI 1.7.1, iptables and runc; it also enables IPv4 forwarding and loads overlayfs. All binary downloads have pinned SHA-256 digests in `scripts/install-deps.sh`; distribution packages use the package manager's verification. Dependencies live in `/usr/local/lib/sandcube/deps/bin`, including gVisor's adjacent `gvisor-bin` directory. The host's containerd binary and service are not reconfigured.

`init` installs missing dependencies, enables forwarding/overlayfs, preallocates a local XFS disk image, formats that new file, mounts it with `prjquota`, and creates SQLite metadata. No partitioning, external database, or manual mount setup is needed. `serve` restores the managed mount after reboot. Advanced users can supply an empty XFS/prjquota mount using `--storage`; only that mode requires an operator-managed mount. `doctor` checks storage, quota enforcement, kernel, overlayfs, cgroup v2/controllers, forwarding, and executables. Startup probes check containerd, the adapter, BuildKit, and API/database health.

The service account is explicitly `root`: the existing adapter needs mount, network namespace, cgroup and project-quota privileges. A nominal unprivileged account would not make this runtime work. Config and private directories are root-only, the API binds loopback by default, and the installer never prints credentials.

## Commands

```sh
curl -fsSL https://github.com/pvelleleth/sandcube/releases/latest/download/install.sh | sh
sudo sandcube init
sudo sandcube serve
sandcube version
```

The release URL becomes usable when the first signed release is published. The source `scripts/install.sh` is a template and deliberately refuses installation until publishing inserts the repository, version and trusted public key.

Installer options: `--systemd` and `--no-deps` (operators who already manage all dependencies). Image builds are enabled by default: `init` installs BuildKit/CNI when needed, and `serve` supervises BuildKit as its fourth process.

SQLite is local and automatically provisioned at `<data-root>/sandcube.db`. There is no `DATABASE_URL` setting or API key authentication. The API is for trusted backends and binds `127.0.0.1:7432` by default; use `--host <private-IP>` and optionally `--port` during initialization for remote backend access. The CLI never sources a shell file or loads the working directory's `.env`.

Config values are JSON-quoted dotenv assignments, for example `SANDCUBE_PORT="7432"`. Edit them as data; do not shell-source the file. `init` refuses to overwrite an existing config or adopt nonempty storage. For existing manual installations, retain their data and config and plan a migration separately; changing paths alone does not migrate containerd, database host budgets or process history.

## Paths and capacity

The default layout is:

```text
/var/lib/sandcube/config.env          # stable root-only discovery/config path
/var/lib/sandcube/storage.xfs        # preallocated managed filesystem image
/var/lib/sandcube/data/              # XFS/prjquota mount, restored by serve
  sandcube.db                        # SQLite metadata, WAL and SHM alongside it
  containerd/                       # content, metadata, snapshots
  process-history/                   # process journals, logs, network records
  builds/                            # temporary image build contexts
  bin/<version>-<content-id>/         # verified internal executables
  tmp/                               # child temporary files
  buildkit/                          # optional build cache/state
  cni/                               # optional CNI address allocations
  serve.lock
/run/sandcube/
  containerd.sock
  runtime.sock
  containerd/                        # volatile containerd task state
  buildkitd.sock                     # optional
  *.toml, buildkit-cni.conflist, serve.lock
```

The config has a stable default path so `serve` requires no arguments. `--config /absolute/path/config.env` places the managed image and data mount beside that file; pass the same option to subsequent commands. `--run-dir` chooses another private runtime directory. Network namespace handles remain in `/run/netns`; the adapter's network allocation lock remains `/run/sandcube-network.lock`.

The managed image uses 75% of available host disk; `--storage-size-mb` chooses an explicit size of at least 512 MiB. Default capacity budgets reserve one CPU when available, 25% of host RAM, and 25% of free space inside the image for overhead. `--capacity-cpu`, `--capacity-memory-mb`, and `--capacity-disk-mb` override budgets. Persisted capacity must match on every startup. Back up SQLite with its backup API or stop the service before copying its database files; do not copy only the main database while WAL writes are active.

## Supervision and systemd

Readiness has a 60-second deadline per child and bounded probes. Any unexpected child exit aborts startup or stops the service with a nonzero exit status. SIGINT/SIGTERM stop the API first, then BuildKit, then the adapter and containerd. Each child has 15 seconds to terminate before SIGKILL. The supervisor reaps every child. Runtime data and snapshots are preserved; task behavior on host/shim loss follows the existing reliability model.

Lifetime locks cover both persistent and runtime roots. Existing live sockets or a bound API address are refused. Stale Unix sockets are removed only after checking that they are sockets and refusing connections. Every extracted payload is verified before reuse; corrupt files fail closed. Content-addressed release directories avoid replacing the adapter path that existing shim log collectors may still execute.

```sh
curl -fsSL https://github.com/pvelleleth/sandcube/releases/latest/download/install.sh | sh -s -- --systemd
sudo sandcube init
sudo systemctl start sandcube
sudo journalctl -u sandcube -f
```

The installer enables, but does not start, the unit. `init` writes the storage/config drop-in and reloads systemd. The unit delegates cgroups, preserves runtime state, and restarts on failure with a rate limit. A 90-second stop deadline allows all children to finish shutdown. Managed image mounts are restored by `serve`; custom storage mounts must be configured to survive reboot.

Existing PostgreSQL installations are not automatically imported. Retire or export their sandboxes before initializing a fresh SQLite installation; keep their original data for recovery. Do not connect a new empty journal to an existing live runtime namespace, because reconciliation treats unknown managed sandboxes as orphans.

For an upgrade, stop the service, rerun the signed installer, then start it. Existing config/state are retained. Previous extracted release directories are retained deliberately; do not remove a version while shim log collectors may still use its adapter. Config/schema migration downgrades are not automatically reversible.

## Release publishing and trust

`.github/workflows/release.yml` builds and tests on native amd64 and arm64 runners, builds static binaries with `infra/release.Dockerfile`, signs the checksum manifest, and attaches all artifacts to a versioned GitHub release. A pushed tag must match `shard.yml`.

Configure a protected GitHub `release` environment with the RSA private PEM secret `RELEASE_SIGNING_KEY`. Keep the same signing key across releases, and publish its public fingerprint through a separately trusted channel. Generate and retain this key outside CI; never commit it. No production signing key is generated or installed by development tests.

For local publishing preparation, place both static binaries at `dist/sandcube-linux-{amd64,arm64}` and run:

```sh
RELEASE_VERSION=0.1.0 RELEASE_REPOSITORY=pvelleleth/sandcube \
RELEASE_SIGNING_KEY=/absolute/private/release-key.pem sh scripts/release.sh
```

The installer pins the public key directly in its generated script, verifies the RSA/SHA-256 signature on `SHA256SUMS`, then verifies every selected artifact before installing it. A checksum or signature mismatch aborts. The initial installer itself is obtained over HTTPS; for independent trust, review/download it and compare the embedded key fingerprint against your trusted channel before running it. There is no insecure verification bypass.

The launcher stores payload offsets, lengths and SHA-256 hashes in a bounded manifest appended to the executable. The signed checksum covers the entire executable including that manifest. Extraction streams the payloads to private temporary files, verifies them, and atomically publishes them. Development `make build` produces the same bundle format with locally linked binaries; it is not a signed portable release.

Dependency installation follows the [gVisor archive layout](https://gvisor.dev/docs/user_guide/install/), [containerd releases](https://github.com/containerd/containerd/releases/tag/v2.2.3), and [BuildKit releases](https://github.com/moby/buildkit/releases/tag/v0.33.0).
