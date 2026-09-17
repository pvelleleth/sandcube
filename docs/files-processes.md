# Phase 3: files and detached processes

All routes require the existing bearer API key. IDs and ownership are scoped to a sandbox; no host PID or host path is accepted. Existing synchronous `/exec` behavior remains available.

## File API

| Method | Route | Behavior |
| --- | --- | --- |
| GET | `/v1/sandboxes/:id/files?path=/workspace` | JSON `entries` containing `name`, `type`, and byte `size` |
| POST | `/v1/sandboxes/:id/files?path=/workspace` | Create one directory; parent must exist |
| GET | `/v1/sandboxes/:id/files/content?path=/workspace/app` | Download exact bytes as `application/octet-stream` |
| PUT | `/v1/sandboxes/:id/files/content?path=/workspace/app&mode=0755` | Upload raw request bytes; atomically create/replace a file |
| DELETE | `/v1/sandboxes/:id/files?path=/workspace/app` | Unlink a file/symlink or remove an empty directory |

Read/write and upload/download use the same content endpoints. Empty files, NULs and non-UTF-8 bytes are supported. No multipart wrapping or JSON encoding is needed. Uploads and downloads are limited to **16 MiB per file**; oversized uploads return 413 without replacing the previous file. Listing is limited to 10,000 entries and returns 413 beyond that limit. Directory ordering is unspecified. `mode` is an optional octal permission value (0000–0777) for writes and directory creation. New files default to 0644, directories to 0755; replacement preserves the previous file's permission bits unless a mode is supplied. Setuid/setgid/sticky bits are not accepted. Writes replace the directory entry, so existing open descriptors continue to refer to the old file.

Both absolute and relative paths are relative to the sandbox root. Repeated separators and `.` are normalized. `..`, NULs and paths exceeding 4096 bytes are rejected. Root listing is supported; root deletion/replacement is forbidden. Parent directories must already exist; deletion is deliberately nonrecursive.

Path confinement uses Linux `openat2` with `RESOLVE_BENEATH`, `RESOLVE_NO_SYMLINKS` and `RESOLVE_NO_XDEV`, followed by descriptor-relative operations. These restrictions apply during resolution, including concurrent rename/symlink changes. Reads inspect a pinned descriptor before opening it for IO, rejecting devices, FIFOs and other special files. Writes use exclusive temporary files and atomic rename, so they cannot overwrite a symlink or hardlink target. A leaf symlink may be safely unlinked; following any symlink for reads, writes or parent traversal is rejected, even if it points inside the sandbox. See the [openat2 reference](https://man7.org/linux/man-pages/man2/openat2.2.html).

Files are accessible while running and stopped. Running sandboxes reuse the actual containerd task rootfs mount; stopped sandboxes temporarily mount their retained snapshot. Mount and file operations serialize with lifecycle changes. The API never launches an in-sandbox utility for file operations, so no shell or language runtime is required in the image.

The supplied `infra/gvisor/runsc.toml` now requires both `overlay2=none` for persistence and `file-access=shared` for visibility of external file changes. Update an installed copy before creating/starting sandboxes; existing tasks must be recreated with stop/start. See [gVisor filesystem configuration](https://gvisor.dev/docs/user_guide/filesystem/). The adapter needs access to containerd's state directory in the same mount namespace; `-containerd-state` defaults to the directory containing its configured containerd socket. Set it explicitly if the daemon's state directory is elsewhere.

## Process API

| Method | Route | Behavior |
| --- | --- | --- |
| POST | `/v1/sandboxes/:id/processes` | Start detached command; return 202 and its `proc_...` ID after launch, without waiting for exit |
| GET | `/v1/sandboxes/:id/processes` | List API-created detached processes, including completed ones |
| GET | `/v1/sandboxes/:id/processes/:pid` | Status, argv, start/completion timestamps and exit code |
| GET | `/v1/sandboxes/:id/processes/:pid/logs` | Captured `stdout`, `stderr`, and `truncated` |
| POST | `/v1/sandboxes/:id/processes/:pid/kill` | SIGKILL the process and return its terminal status; repeated cancellation is safe |

Example launch:

```json
{"command":["/workspace/app"],"cwd":"/workspace","env":{"MODE":"test"}}
```

`command` is an argv array, with no implicit shell. Detached commands have no execution timeout and do not accept `timeout_seconds`; use synchronous `/exec` for timed commands. A launch failure returns an error and removes the incomplete tracking record. `exit_code` and `completed_at` are null while running, and populated once the process exits. Nonzero exit codes are normal process outcomes. A runtime wait failure produces status `error` and a diagnostic rather than inventing an exit code.

Each stream retains its first **1 MiB**. Additional output is drained and discarded, and `truncated` becomes true. This bounds memory and prevents a noisy command from blocking on full pipes. Logs are JSON text, not a binary transfer channel. Polling log retrieval works during execution and after completion. It is not a streaming/TTY endpoint.

Tracking and IO live in the private runtime adapter, independently of the client connection and public Crystal API process. Disconnecting or restarting the public API does not stop detached work. Process creation serializes with sandbox lifecycle transitions; it does not hold a lifecycle lock while the command runs. Sandbox stop kills all tasks/processes and waits for tracked exits before returning. Start preserves files and never relaunches previous detached commands. Deletion also removes tracking and captured logs, without affecting other sandboxes or the source image.

Cancellation targets the requested process, not its descendants; use an application's foreground executable (or shell `exec`) when cancelling that workload individually. Sandbox stop/delete terminates all descendants as well. Listing covers detached commands created through this API, not init, synchronous execs, or arbitrary forked descendants.

Process history and logs are durable on disk and survive adapter restart. Each stream retains up to 1 MiB while collectors continue draining output; failed launches also remain in history. History is retained until sandbox deletion or TTL cleanup. See [Phase 4 reliability](reliability.md) for recovery, keyed process/exec retries and retention details. Files remain persisted in containerd snapshots across service restarts.

## Verification

```sh
make test GO="$PWD/.tools/go/bin/go"
make integration GO="$PWD/.tools/go/bin/go"
```

The integration harness needs the same dedicated containerd/gVisor setup and cached BusyBox image as Phase 1. It now exercises the Phase 3 workflow plus all existing lifecycle regressions. It creates an executable application through the upload API, starts it detached, restarts the public API, reconnects to retrieve logs and generated artifacts, and cancels it. Additional checks cover exact binary/empty transfers, oversized uploads, live overwrite visibility, missing files, traversal and symlink escapes, independent concurrent commands, exit codes, large stdout/stderr, failed launches, stopped file access, stop/start persistence, and deletion with running processes.

Go tests additionally exercise hostile concurrent symlink replacement, special files/FIFOs, hardlink-safe replacement, file modes, bounded output under concurrent writes, process routing/validation and cross-sandbox lookup. Crystal specs check unauthenticated API routing, binary transport, decoded traversal, and body limits. Tests run with Go's race detector and vet. Database specs always run against temporary SQLite files without database services or credentials.
