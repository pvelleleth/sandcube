# Phase 5 — Resource Enforcement and Secure Networking

Create accepts `disk_mb` (MiB, 16–1,048,576, default 1024). Responses and metrics include the storage reservation. CPU, memory and PID cgroup limits retain their existing request fields. Sandbox swap is disabled so memory pressure cannot consume unreserved host swap. Cgroup v2 is required; group OOM killing terminates the entire task instead of leaving a live sentry with a dead helper. Writable disk blocks and inodes are charged to a kernel XFS project quota; a sandbox cannot bypass it by writing as root, using the file API, renaming files, restarting or stopping. Sparse files are charged for allocated blocks, not logical size. In-memory filesystems are bounded separately by memory/cgroup and mount limits.

## Host setup

Use a dedicated containerd instance and a dedicated XFS filesystem mounted with `prjquota` for its overlay snapshotter. The XFS filesystem must belong to this containerd instance: its numeric overlay snapshot IDs are reserved as project IDs. Do not share that project-ID space with another containerd instance or operator-assigned projects. The adapter verifies filesystem type, enforcement mount options, project inheritance and hard limits. It rejects unsupported filesystems instead of silently running without quotas. Both the `fs` and `work` directories share the sandbox's budget. An inode hard limit of 256 inodes per requested MiB bounds empty-file growth too.

`sandcube init` provisions and mounts this storage automatically, and `serve` configures its private containerd instance. For manual development or a custom `--storage` mount, provision storage before starting containerd and set its `root` to that mount. Keep `overlay2=none` and `file-access=shared` in the provided gVisor configuration.

Install `iproute2`, `nftables`, `conntrack` and `procps` (`ip`, `nft`, `conntrack`, `sysctl` on the adapter's PATH). Enable `net.ipv4.ip_forward=1` persistently. The adapter refuses startup when forwarding is disabled. It owns only its `scn…` interfaces, matching named namespaces and per-endpoint nftables tables; it never flushes the host firewall or changes its forwarding policy.

If an existing host firewall has a forwarding DROP policy, permit IPv4 forwarding from `scn*` and established/related return traffic to `scn*` in that firewall. Sandcube's separate nftables chains still drop prohibited packets, even if another chain accepts them. Test these allowances after a firewall reload. Do not flush Sandcube's tables while tasks are running. Reserve `198.18.0.0/15` exclusively for sandbox links; it is never an allowed outbound destination.

`sandcube init` detects and persists allocatable budgets automatically. Manual development with the standalone API requires explicit budgets, for example:

```sh
export SANDCUBE_CAPACITY_CPU=2
export SANDCUBE_CAPACITY_MEMORY_MB=1024
export SANDCUBE_CAPACITY_DISK_MB=8192
```

These are examples, not hardware detection. Set budgets below physical capacity and leave room for the OS, gVisor overhead, containerd, SQLite, builds, immutable images and retained process logs. Those host workloads are outside sandbox quotas. Run one API process with its local database on this host. Budgets are persisted in `host_capacity`; a process with different values fails startup. To change budgets, stop all API processes, update that singleton row to the new values, and restart with matching environment settings. Reducing a budget never evicts existing reservations; new admission fails until usage fits.

Run one adapter per containerd namespace and use a single sandbox control-plane database for the host. The adapter Unix socket is trusted, mode 0600, and must remain inaccessible to users and sandboxes. Operator-created runtime objects block admission until reconciliation cleans them up.

## Reservation and recovery semantics

| Operation | CPU / memory | Disk | Networking |
| --- | --- | --- | --- |
| Create | Reserved with committed intent, before runtime IO | Reserved before snapshot creation | Firewall before interfaces go up |
| Start / restart | Checked and reserved before accepting intent | Existing reservation retained | Recreated before task starts |
| Stop | Released after task and network cleanup succeed | Retained, with quota enforced | Link, namespace, conntrack and firewall removed |
| Delete / expiration | Retained until cleanup succeeds | Released only after physical reclamation | Removed after task termination |
| Uncertain runtime response | Reservation retained | Reservation retained | Durable ownership journal retained |

Admission sums durable reservation columns within the serialized lifecycle operation and SQLite intent transaction. It returns `409 INSUFFICIENT_CAPACITY` without committing a sandbox or image reference if any budget is exceeded. Inventory failure or unaccounted runtime containers prevent admission. Reconciliation releases CPU/memory for confirmed stopped tasks and conservatively retains disk for missing containers until deletion checks storage cleanup.

The adapter journals quota and network ownership under `<history-root>/<namespace>/.quotas` and `.networks` before side effects. Preserve the history directory across service and host restarts. A stale namespace, partial veth, firewall-only setup, residual conntrack state, or completed teardown with an old journal record is retried idempotently. Startup reconciles orphan resources before listening. Runtime lifecycle and reconciliation operations are serialized so a sweep cannot delete a network being started.

Containerd can defer physical snapshot deletion after removing metadata. The adapter waits up to ten seconds for the directory to disappear and XFS to report zero project blocks and inodes. On timeout/error the request fails and its reservation stays held; reconciliation retries. Network teardown clears original-source/destination conntrack entries before releasing the firewall/address, preventing a subsequent sandbox from inheriting old NAT flows. Cleanup never deletes host paths from journal data. Quota limits are cleared only after zero usage is confirmed.

## Network boundary

Each running sandbox gets a routed IPv4 `/30`, its own network namespace and veth, and outbound masquerading. The resolver is a platform-owned read-only mount pointing at public DNS (1.1.1.1 and 8.8.8.8). Image-supplied resolver files do not override it. Loopback stays internal to the sandbox. IPv6 egress is disabled and dropped rather than left as an unfiltered alternative.

An early prerouting filter rejects non-IPv4 packets, spoofed source addresses, host-local destinations (including public host addresses), private/special-use ranges, link-local metadata, shared-address metadata and Azure's platform address. A forward filter repeats destination protection after DNAT, restricts transport protocols, and permits only established/related inbound flows. INPUT traffic from sandbox interfaces is dropped unconditionally. Peer links use the denied benchmark range. Rules apply to numeric destinations after DNS resolution, so changing a hostname to a protected IP does not bypass them. This permits general public internet access; it is not an application-domain allowlist.

## Upgrading earlier phases

`init` provisions a new quota-enabled XFS image on ordinary VPS storage; an existing dedicated XFS mount remains available through `--storage`. Existing PostgreSQL metadata and legacy snapshots are not automatically imported. Export or retire old sandboxes before initializing a fresh deployment, and retain the old state for recovery.

## Testing

```sh
# Isolated SQLite databases; kernel quota test needs a disposable XFS mount.
SANDCUBE_TEST_XFS=/mnt/sandcube-test make test

# An empty sandcube-test namespace; SQLite state is temporary.
SANDCUBE_CONTAINERD=/run/sandcube-test/containerd.sock make integration-resources
```

For a disposable test filesystem, create a new sparse image in a private temporary directory, format that new file with `mkfs.xfs`, mount it with `loop,prjquota`, and point a separate containerd `root` there. Its `state` and socket must also be separate. Set `SANDCUBE_CONTAINERD_STATE` when the state directory differs from the socket's parent. Unmount and remove the test image only after the test runtime has stopped. This integration harness uses temporary SQLite state, does not provision storage, and refuses a namespace with existing live sandboxes.

The suite includes the Phase 4 SIGKILL/lost-response harness, real admission races, package download, protected-destination probes, guest and stopped-API quota exhaustion, persistence, and SIGKILL at internal firewall/netns/veth/address creation and firewall removal boundaries. Test-only executable wrappers inject those faults after running real `ip`/`nft`; production code has no fault switches. `SANDCUBE_TEST_PACKAGE_URL` can override the public package-index URL for environments with restricted registry access.
