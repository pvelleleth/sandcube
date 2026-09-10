# Milestone 2: Dockerfile images

The Crystal API owns image state and build orchestration. `buildctl` builds a local OCI archive; the Go adapter imports it into its containerd namespace and unpacks it into overlayfs. A READY image is reused directly, with a separate writable snapshot per sandbox.

## Setup

Install PostgreSQL, `shards`, and the official [BuildKit binaries](https://github.com/moby/buildkit/releases). Run `shards install` and `make build`. The API applies the additive, idempotent migration in `migrations/001_images.sql` when `DATABASE_URL` is configured. Use a database dedicated to this service.

Run **one API instance per database/namespace**, using a private build directory shared with the runtime adapter. The API holds an exclusive lock on this directory. Run BuildKit separately with its private Unix socket, process isolation, and an isolated bridge/CNI network. Do not enable `security.insecure`, `network.host`, device entitlements, or `--oci-worker-no-process-sandbox`. Builds receive only their uploaded context and build arguments; registry credentials, SSH agents, secret mounts, and host environment variables are not forwarded.

For the bundled BuildKit release (v0.33.0), the following uses its built-in bridge networking and bundled `buildkit-cni-*` helpers (put the release's `bin` directory on PATH):

```sh
sudo buildkitd --root /var/lib/sandcube-buildkit \
  --addr unix:///run/sandcube-buildkit/buildkitd.sock \
  --oci-worker-net bridge --containerd-worker=false --oci-max-parallelism 2
```

An explicit CNI configuration alternative is in `infra/buildkit/`. Install the CNI configuration at `/etc/sandcube/buildkit-cni.json` and standard CNI plugins in `/opt/cni/bin` before using that TOML. Restrict build network access to sensitive host/private services with host firewall rules appropriate to the deployment. BuildKit build execution has its own OCI worker; sandbox execution continues to require gVisor.

API configuration:

| Variable | Default / meaning |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection URL; required for images |
| `SANDCUBE_BUILD_ROOT` | `/var/lib/sandcube/builds`, mode 0700 |
| `SANDCUBE_BUILDKIT_ADDRESS` | `unix:///run/buildkit/buildkitd.sock` |
| `SANDCUBE_BUILDCTL` | `buildctl`, executable path |

Pass the same build directory to the adapter with `-build-root`. The adapter and API must have filesystem access to it. Existing runtime/API configuration is unchanged. Without `DATABASE_URL`, Phase 1 raw OCI image creation remains available, and image routes return `503 IMAGES_UNAVAILABLE`.

## API

All routes require the existing Bearer API key. Submit JSON for a Dockerfile without context:

```sh
curl -sS http://127.0.0.1:8080/v1/images \
  -H "Authorization: Bearer $SANDCUBE_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"name":"tools","dockerfile":"FROM alpine:3.22\nRUN apk add --no-cache curl\nWORKDIR /workspace","build_args":{}}'
```

For an uploaded context:

```sh
tar --format=ustar -czf context.tar.gz -C context .
curl -sS http://127.0.0.1:8080/v1/images \
  -H "Authorization: Bearer $SANDCUBE_API_KEY" \
  -F 'name=tools' -F 'dockerfile=<Dockerfile' \
  -F 'context=@context.tar.gz' -F 'build_args={"VERSION":"example"}'
```

JSON also accepts `context_tar_gz`, a base64-encoded tar.gz. Multipart accepts `dockerfile`, `context`, `name`, and `build_args` (a JSON string map). Duplicate or unknown fields are rejected. The submitted `dockerfile` field is authoritative; an archive's Dockerfile does not replace it.

The response is **202 Accepted** with `id: img_...` and `status: BUILDING`. Poll `GET /v1/images/:id` until READY or ERROR. Metadata includes optional name, Dockerfile, timestamps, OCI reference/digest, and an error message for failed builds. Image state values are uppercase.

Create any number of sandboxes from a READY ID:

```sh
curl -sS http://127.0.0.1:8080/v1/sandboxes \
  -H "Authorization: Bearer $SANDCUBE_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"image_id":"img_REPLACE_ME","command":["/bin/sleep","infinity"]}'
```

The existing explicit long-running `command` requirement remains: choose an executable present in your image. Provide exactly one of `image_id` or the Phase 1 `image` reference. Create/inspect responses include `image_id` for managed images. A missing ID returns 404; an image that is not READY returns 409.

`DELETE /v1/images/:id` refuses BUILDING images and returns `409 IMAGE_IN_USE` for images referenced by any sandbox, including stopped sandboxes and incomplete creations. Delete those sandboxes first. PostgreSQL row locks serialize reservations against deletion; the adapter independently checks container references. Successful image deletion leaves a DELETED metadata tombstone and is idempotent. Unknown IDs return 404. Containerd garbage collection preserves content shared with other images and snapshots. BuildKit's own build cache is managed separately by BuildKit GC.

## Limits and recovery

Requests are bounded to 48 MiB, Dockerfiles to 64 KiB, contexts to 256 MiB expanded and 10,000 entries, and arguments to 100 string entries (8 KiB each). Contexts support regular files and directories in ustar archives. Traversal, absolute paths, backslashes, duplicate paths, symlinks, hard links, devices, and extended/PAX/GNU headers are rejected. Produce portable archives with `tar --format=ustar`; this restriction is intentional.

One build runs at a time, with at most eight pending builds. Each build has a 30-minute timeout and bounded diagnostic capture. Temporary context/Dockerfile/OCI files are removed on success, failure, and invalid upload. Partial imports are cleaned up on build failure. A runtime deletion failure leaves DELETING, which can be retried; it cannot be used to create new sandboxes.

On API startup, interrupted BUILDING records become ERROR and abandoned build directories are removed. Builds are not resumed automatically. A hard crash can leave an imported reference; deleting the ERROR image removes it. Sandbox reservations survive restarts and failed rollback, so an uncertain runtime outcome cannot silently allow image deletion. Retry sandbox deletion to release those reservations. Full runtime reconciliation and distributed/multi-instance workers remain outside this milestone.

## Verification

```sh
# Use a dedicated test database, never a production DATABASE_URL.
TEST_DATABASE_URL=postgres://... make test

# Requires running containerd, BuildKit and gVisor; these tests launch their own API/adapter.
TEST_DATABASE_URL=postgres://... \
SANDCUBE_BUILDKIT_ADDRESS=unix:///run/sandcube-buildkit/buildkitd.sock \
make integration-images
```

The acceptance test installs curl, copies a file, verifies build arguments/ENV/WORKDIR, then disables buildctl and creates two gVisor sandboxes. It proves independent filesystems, stop/start persistence, durable metadata, failure handling, upload validation, temporary cleanup, failed-start rollback, and reference-protected/idempotent image deletion. The original `scripts/integration.py` remains the Phase 1 regression suite. Tests reserve the `sandcube-test` namespace and share an exclusive integration lock.
