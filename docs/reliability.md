# Phase 4 — Reliability

The service automatically creates `sandcube.db` in its local data directory for the sandbox journal, lifecycle request deduplication, reconciliation, TTL and `/metrics`. SQLite uses WAL, full synchronous writes, foreign keys, and one pooled connection. Schema creation runs during initialization and startup. A lifetime file lock permits one API process per data directory; a mutex serializes lifecycle operations. Journal transactions commit before runtime IO, so accepted intent survives a crash. Database specs always run using temporary on-disk SQLite databases.

Only one API instance may own image builds. Additional lifecycle API instances must set `SANDCUBE_IMAGE_API_ENABLED=false`; this disables their image endpoints and interrupted-build recovery while preserving image reservations for sandbox creation.

Use one dedicated containerd namespace per database. The reconciler treats containers carrying `sandcube.managed=true` and the runsc runtime identity as service-owned. Unknown managed containers are deleted. Before upgrading an existing installation, migrate its live sandbox inventory into the journal or retire those sandboxes; Phase 1–3 did not persist sandbox configuration in SQLite. Do not point the reconciler at an unrelated namespace. Unlabelled containers and snapshots are not orphan-cleanup candidates.

The adapter's `-history-root` defaults to `/var/lib/sandcube/processes`, with a namespace subdirectory. Keep this directory on persistent local storage and retain it across upgrades and restarts. Its metadata uses atomic rename and file/directory fsync. The adapter acquires an exclusive socket lock before replacing a stale socket; a live adapter or non-socket path is rejected. Use one adapter per namespace with the same socket/history configuration on each restart.

## Lifecycle recovery

Create reserves its image and records configuration and intent in one SQLite transaction. Start, stop, restart and delete also commit intent before calling the adapter. Only one API process runs per host/data directory, with serialized lifecycle operations. The adapter serializes operations per sandbox, including process preparation and file access. Synchronous exec releases that lock while waiting, so stop/delete can interrupt it.

The reconciler runs at startup and every `SANDCUBE_RECONCILE_SECONDS` (default 15). It resumes pending transitions, refreshes runtime status, marks missing containers as `error`, deletes unknown managed containers, and cleans positively labelled orphan snapshots and process history directories. Inventory failure aborts the sweep; it is never treated as an empty inventory. Failed cleanup remains retryable. Explicit deletion can supersede a pending transition.

Create is idempotent at the adapter boundary: an existing container must have the same configuration fingerprint. A labelled snapshot left between snapshot preparation and container creation is removed before retry. A definitive failed create is compensated and its error response is retained; a transport failure leaves intent pending because the side effect may have succeeded.

Restart journals the stop-to-start boundary. Recovery after that boundary starts the existing snapshot without repeating the stop. Sandbox files and reusable image content are never recreated during start or stop.

## Request retries

Send `Idempotency-Key` with sandbox create/start/stop/restart/delete. Use 1–200 printable ASCII characters, and reuse exactly the same method, path and create body on retries. SQLite retains the response; conflicting reuse returns HTTP 409. Create replay returns the original ID and HTTP 201. Replaying a completed restart does not restart the workload again. Stored responses describe the original operation; use GET for current state. Request records and sandbox tombstones are retained indefinitely so an old key cannot silently create a new sandbox.

Detached process creation and synchronous exec also accept `Idempotency-Key`. These keys are scoped to the sandbox and endpoint and identify a durable process record. Matching retries return that process or its result; changed command/options return 409. A process whose start was interrupted is reported as an error rather than executed again. Process retry records expire with sandbox deletion. File and image submission requests do not provide keyed replay guarantees.

All acceptance harnesses create their own temporary SQLite databases. See [resource budgets and XFS/network prerequisites](resources-networking.md).

## Processes and logs

Both detached and synchronous commands receive durable process records. Failed launches remain in history. Independent FIFO collectors survive API/adapter SIGKILL, preserve stdout and stderr separately, fsync captured output, and drain output beyond the 1 MiB per-stream capture limit. Collector processes exit when the shim closes the pipes; collectors whose exec never materializes time out while opening their FIFOs. They must not be killed with the adapter's entire process group/cgroup when deploying it.

On adapter restart, live execs are reattached using their runtime IDs, completed execs retain their exit codes, and interrupted starts become explicit errors. Exit metadata is saved before runtime process deletion. If containerd has already lost the process record, history reports an unknown exit as an error rather than inventing an exit code. Processes are never automatically relaunched. Synchronous timeout deadlines survive adapter restart and are enforced when the adapter is available.

Deletion/TTL removes only that sandbox's snapshots and process history/logs. Stop retains both. Per-stream output is bounded, but the number of retained process records is not; provision disk space or use sandbox TTLs. These guarantees cover API/adapter crashes, not recovery of running workloads across host or shim destruction.

## TTL and observability

Create accepts positive `ttl_seconds`. Expiration uses SQLite time and applies to running and stopped sandboxes. Expiration supersedes pending startup work and follows the same retryable deletion path. Reusable image reservations are released only after runtime deletion succeeds. Image objects and base layers are not TTL targets.

`GET /metrics` returns Prometheus text with durable lifecycle/cleanup/reconciliation counters, sandbox state counts, reserved CPU/memory/disk, runtime request failures and duration, per-sandbox CPU/memory/snapshot usage, process counts, and process-history disk usage. `sandcube_runtime_up` and `sandcube_resource_scrape_errors` distinguish unavailable measurements from zero usage. Runtime request counters reset with adapter restart; journal counters persist in SQLite. Lifecycle and adapter events are JSON and include IDs, durations or failure details.

## Verification

```sh
make build test GO="$PWD/.tools/go/bin/go"
python3 scripts/integration_reliability.py
```

Use an empty `sandcube-test` namespace. The harness creates a temporary SQLite database and injects SIGKILL before and after create/start/stop/delete runtime operations through a Unix HTTP proxy, then restarts both services and retries the original request. It also checks concurrent keys, process exit and logs during adapter downtime, live-process recovery, exec lost-response retries, persistent files, TTL, labelled snapshot/container orphans, unlabelled snapshot preservation, metrics and image preservation. No production fault-injection switch is needed.

The database specs inject transport failures on both sides of lifecycle side effects, including rollback and retry behavior. Go tests cover durable metadata, corrupt-history rejection, bounded independent stream capture and filesystem safety, and run with the race detector.
