# Product Requirements Document: Container Sandbox Service

## 1. Overview

Build a self-hosted sandbox service for creating, running, stopping, restarting, and destroying isolated Linux environments on a single VPS.

The service is intended to provide a generic programmable sandbox runtime for arbitrary workloads, including AI agents, development environments, automation, browsers, and other software defined by the user.

Each sandbox must support:

* Arbitrary command execution
* Persistent filesystem state during stop/start cycles
* File read/write/upload/download
* Network access
* Resource limits
* Start/stop/restart lifecycle management
* Automatic expiration
* Programmatic API access
* Custom reusable sandbox images built from Dockerfiles

The platform will use:

* **Crystal** for the primary API, host daemon, lifecycle management, filesystem handling, image management, and service logic
* **Go** only for a small containerd integration module
* **containerd** as the container runtime
* **gVisor (`runsc`)** as the sandbox isolation runtime
* **PostgreSQL** for persistent sandbox metadata
* **Dockerfiles** as the mechanism for defining custom sandbox environments
* **BuildKit** for building OCI-compatible images

The initial version runs entirely on a single VPS.

---

# 2. Goals

The system must make it easy to programmatically define a reusable sandbox image and launch isolated environments from that image.

Primary workflow:

```text
Provide Dockerfile
        ↓
Build image
        ↓
Store reusable image
        ↓
Create sandbox from image
        ↓
Run arbitrary workloads
        ↓
Stop sandbox
        ↓
Start sandbox later
        ↓
Continue with preserved filesystem state
        ↓
Destroy sandbox
```

Primary goals:

1. Build reusable sandbox images from user-provided Dockerfiles.
2. Create sandboxes from previously built images.
3. Start sandboxes quickly from those images.
4. Execute arbitrary commands inside sandboxes.
5. Stream stdout/stderr from running commands.
6. Persist sandbox filesystem state across stop/start operations.
7. Support arbitrary software defined by the sandbox image.
8. Stop sandboxes without deleting their data.
9. Restart stopped sandboxes later.
10. Automatically delete expired sandboxes.
11. Enforce CPU, memory, disk, and process limits.
12. Keep container-runtime-specific logic isolated behind a small Go module.

---

# 3. Non-Goals

The first version does not need:

* Multiple VPS hosts
* Scheduler
* Host selection
* Kubernetes
* Firecracker
* Multi-region deployment
* Usage-based billing
* Customer billing
* Public image marketplace
* Live migration
* Automatic sandbox migration
* Distributed storage
* GPU workloads
* Windows sandboxes
* macOS sandboxes
* High-availability control plane
* Preinstalled development environments
* Built-in browser support
* Browser lifecycle APIs
* Browser proxies
* Browser profile management
* Built-in Node/Python/browser images

The sandbox service should remain deliberately generic.

---

# 4. High-Level Architecture

```text
                    Client / Agent SDK
                           |
                           v
                +----------------------+
                |     Sandbox API      |
                |       Crystal        |
                +----------+-----------+
                           |
                 +---------+---------+
                 |                   |
                 v                   v
             PostgreSQL           sandboxd
                                  Crystal
                                     |
                                     v
                              Go Runtime Shim
                                     |
                                     v
                                 containerd
                                     |
                                     v
                                   gVisor
                                     |
                                     v
                              +-------------+
                              |   Sandbox   |
                              |-------------|
                              | filesystem  |
                              | user image  |
                              | processes   |
                              +-------------+
```

Everything runs on the same VPS.

There is no scheduling layer.

---

# 5. Major Components

## 5.1 Sandbox API

Language:

```text
Crystal
```

Responsibilities:

* Public HTTP API
* Authentication
* Sandbox creation
* Sandbox lifecycle requests
* Image creation
* Image metadata
* Command execution
* File operations
* TTL management
* Resource configuration
* Error normalization

The API and `sandboxd` may initially run in the same Crystal application.

They should still be logically separated in the codebase.

---

## 5.2 Host Daemon (`sandboxd`)

Language:

```text
Crystal
```

The VPS runs one `sandboxd` instance.

`sandboxd` is responsible for machine-local sandbox operations.

Responsibilities:

* Create sandbox
* Start sandbox
* Stop sandbox
* Restart sandbox
* Destroy sandbox
* Execute processes
* Stream process output
* Read/write files
* Manage sandbox storage
* Track sandbox health
* Track resource usage
* Build sandbox images
* Manage locally available images
* Reconcile runtime state with PostgreSQL

`sandboxd` should not contain significant containerd-specific implementation details.

Instead it calls the Go runtime module.

---

# 6. Container Runtime Module

Language:

```text
Go
```

This module should remain intentionally small.

Purpose:

Provide a clean interface between Crystal and containerd.

The Go runtime module should expose only the container operations required by the sandbox platform.

Conceptual interface:

```text
CreateContainer
StartContainer
StopContainer
DeleteContainer

ExecProcess
KillProcess

InspectContainer
ListContainers
GetMetrics

ImportImage
RemoveImage
InspectImage
```

It should use the official containerd Go libraries internally.

Communication between Crystal and the Go module should use:

```text
Unix domain socket + HTTP/JSON
```

for V1.

The module is strictly an implementation adapter.

Business logic remains in Crystal.

---

# 7. Sandbox Images

Sandbox images are reusable environment definitions.

A user provides a Dockerfile.

Example:

```dockerfile
FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y git curl python3 python3-pip

WORKDIR /workspace
```

The platform builds this Dockerfile into a reusable sandbox image.

Conceptually:

```text
Dockerfile
    ↓
build
    ↓
image
    ↓
img_abc123
    ↓
create many sandboxes from img_abc123
```

Images are immutable after creation.

To change an image, the user creates a new image.

---

# 8. Image Creation

Endpoint:

```http
POST /v1/images
```

The user provides:

* Dockerfile contents
* Optional build context
* Optional image name
* Optional build arguments

Example request:

```json
{
  "name": "agent-env",
  "dockerfile": "FROM ubuntu:24.04\nRUN apt-get update && apt-get install -y git curl\nWORKDIR /workspace"
}
```

Example response:

```json
{
  "id": "img_abc123",
  "name": "agent-env",
  "status": "building"
}
```

Image states:

```text
BUILDING
READY
ERROR
DELETING
DELETED
```

Build flow:

```text
Client
   |
POST /images
   |
   v
Crystal API
   |
   +--> save build metadata
   |
   +--> execute image build
   |
   v
BuildKit
   |
   v
OCI-compatible image
   |
   v
containerd image store
   |
   v
READY
```

---

# 9. Dockerfile Build System

The platform must support building OCI-compatible images from Dockerfiles.

The sandbox service should not parse or implement Dockerfile behavior itself.

Use:

```text
BuildKit
```

Conceptually:

```text
Crystal
   |
   v
BuildKit
   |
   v
OCI image
   |
   v
containerd
```

BuildKit handles:

* Dockerfile parsing
* Image layers
* Build cache
* COPY
* RUN
* ENV
* WORKDIR
* build arguments
* base-image pulling

---

# 10. Build Context

Dockerfiles may require additional files.

Example:

```dockerfile
FROM node:22

WORKDIR /app

COPY package.json .
RUN npm install

COPY . .
```

Image creation must therefore optionally accept a build context.

For V1, support:

```text
tar.gz build context
```

Example:

```text
build-context.tar.gz
├── Dockerfile
├── package.json
├── package-lock.json
└── src/
```

The service extracts the context into a temporary build directory and passes it to BuildKit.

Temporary build files must be deleted after the build completes.

---

# 11. Image Identity

Every built image receives a platform ID.

Example:

```text
img_01JXYZ...
```

Images also contain the underlying OCI digest.

Database fields:

```text
id
name
status
oci_reference
oci_digest
dockerfile
created_at
updated_at
error_message
```

Example:

```text
id:            img_abc123
name:          agent-env
oci_reference: sandbox-images/agent-env:abc123
oci_digest:    sha256:...
```

---

# 12. Image Reuse

Once an image is READY, it can be used to create any number of sandboxes.

Example:

```text
img_agent_env
      |
      +----> sbx_001
      |
      +----> sbx_002
      |
      +----> sbx_003
```

Creating a sandbox should never rebuild the Dockerfile.

It should start directly from the existing image.

---

# 13. Default Image Selection

The API may support a configured default image.

Example:

```text
default_image_id = img_agent_env
```

Then:

```http
POST /v1/sandboxes
```

may omit `image_id`.

The configured default image is used automatically.

This enables:

```text
build image once
      ↓
always launch from this image
```

---

# 14. Sandbox Lifecycle

Every sandbox has the following lifecycle states:

```text
CREATING
RUNNING
STOPPING
STOPPED
STARTING
DELETING
DELETED
ERROR
```

Valid transitions:

```text
CREATING
   |
   v
RUNNING
   |
   +---------> STOPPING ---------> STOPPED
   |                                |
   |                                v
   |                             STARTING
   |                                |
   |                                v
   +<---------------------------- RUNNING
   |
   v
DELETING
   |
   v
DELETED
```

Failure from any transition may result in:

```text
ERROR
```

---

# 15. Create Sandbox

Endpoint:

```http
POST /v1/sandboxes
```

Example request:

```json
{
  "image_id": "img_abc123",
  "cpu": 2,
  "memory_mb": 2048,
  "disk_mb": 10240,
  "ttl_seconds": 3600
}
```

If `image_id` is omitted, the configured default image may be used.

Example response:

```json
{
  "id": "sbx_abc123",
  "image_id": "img_abc123",
  "status": "running",
  "cpu": 2,
  "memory_mb": 2048,
  "disk_mb": 10240
}
```

Creation flow:

```text
Client
  |
POST /sandboxes
  |
  v
Sandbox API
  |
  +--> validate image
  |
  +--> check local VPS capacity
  |
  +--> create DB record: CREATING
  |
  v
sandboxd
  |
  +--> call Go runtime shim
  |
  +--> create container from image
  |
  +--> create writable snapshot
  |
  +--> use gVisor runtime
  |
  +--> start sandbox
  |
  v
RUNNING
```

---

# 16. Sandbox Storage Model

Each sandbox consists of:

```text
immutable base image
        +
sandbox-specific writable snapshot
```

Conceptually:

```text
img_abc123
    |
    v
containerd snapshot
    |
    v
sbx_abc123 mutable filesystem
```

Anything installed or created inside the sandbox belongs to that sandbox only.

For example:

```text
Image:
  /usr/bin/python
  /workspace

Sandbox:
  pip install foo
  git clone repository
  create output.json
```

These modifications persist across stop/start.

They do not modify the original image.

---

# 17. Stop Sandbox

Endpoint:

```http
POST /v1/sandboxes/:id/stop
```

Stopping a sandbox must:

* Stop running processes
* Stop the container task
* Release active CPU and memory usage
* Preserve the container's writable snapshot
* Preserve filesystem contents
* Preserve sandbox metadata

Stopping must NOT:

```text
delete container metadata
delete writable snapshot
delete sandbox files
delete database metadata
```

Example:

```text
RUNNING

git repo exists
packages installed
files generated

        ↓ stop

STOPPED

filesystem remains

        ↓ start

RUNNING

git repo still exists
packages still installed
files still exist
```

---

# 18. Start Sandbox

Endpoint:

```http
POST /v1/sandboxes/:id/start
```

Starting a stopped sandbox must:

1. Verify its runtime state still exists.
2. Verify sufficient VPS resources exist.
3. Create/start a new container task using the existing container and writable snapshot.
4. Restore active resource accounting.
5. Mark sandbox RUNNING.

The sandbox must retain the same:

```text
sandbox ID
image ID
container
writable snapshot
filesystem
environment metadata
```

---

# 19. Restart Sandbox

Endpoint:

```http
POST /v1/sandboxes/:id/restart
```

Equivalent to:

```text
stop
start
```

but handled as one lifecycle operation.

The writable filesystem must remain unchanged.

---

# 20. Destroy Sandbox

Endpoint:

```http
DELETE /v1/sandboxes/:id
```

Destroying permanently removes:

```text
container
writable snapshot
sandbox filesystem
sandbox metadata
runtime state
```

The original reusable image remains untouched.

Example:

```text
img_abc123
   |
   +-- sbx_1 -- DELETE
   |
   +-- sbx_2 -- still running
   |
   +-- sbx_3 -- still stopped
```

Deletion should be idempotent.

---

# 21. Generic Environment Model

The sandbox service must not assume that any particular software is installed.

The user's Dockerfile fully defines the environment.

Users may choose arbitrary base images:

```text
ubuntu
debian
alpine
node
python
golang
rust
custom image
```

Examples of optional software users may install themselves:

```text
git
Node.js
Python
Chromium
Playwright
Selenium
Java
databases
compilers
AI agent runtimes
```

The sandbox platform does not need to know about any of them.

---

# 22. Arbitrary Workloads

The platform must treat all software inside a sandbox generically.

For example, if a user wants a browser-enabled sandbox:

```dockerfile
FROM node:22-bookworm

RUN apt-get update && \
    apt-get install -y chromium

RUN npm install -g playwright

WORKDIR /workspace
```

They can then start Chromium through the normal exec API:

```json
{
  "command": [
    "/usr/bin/chromium",
    "--headless=new",
    "--remote-debugging-port=9222"
  ]
}
```

No browser-specific sandbox API is required.

The same model applies to:

```text
web servers
databases
coding agents
language servers
background workers
browser automation
CLI tools
```

---

# 23. Command Execution

Endpoint:

```http
POST /v1/sandboxes/:id/exec
```

Example request:

```json
{
  "command": ["bash", "-lc", "npm install && npm test"],
  "cwd": "/workspace",
  "env": {
    "NODE_ENV": "development"
  },
  "timeout_seconds": 300
}
```

The service must not assume `bash` exists.

The requested executable must exist in the user's image.

Required features:

* stdout streaming
* stderr streaming
* exit code
* timeout
* cancellation
* optional TTY
* environment variables
* custom working directory

---

# 24. Process Management

Every exec operation receives a process ID.

Example:

```json
{
  "process_id": "proc_xyz789"
}
```

Endpoints:

```text
GET  /v1/sandboxes/:id/processes
POST /v1/sandboxes/:id/processes/:process_id/kill
```

Processes are sandbox-generic.

There are no special process types.

---

# 25. Long-Running Processes

The exec API must allow processes that continue running independently of the initial HTTP request.

Example:

```text
npm run dev
chromium
python server.py
agent-runtime
```

The caller should be able to:

```text
start process
receive process ID
disconnect
reconnect to logs/status later
kill process
```

Exact implementation may be deferred beyond the first minimal version, but the process abstraction should support it.

---

# 26. File API

Required operations:

```text
Read file
Write file
Upload file
Download file
List directory
Create directory
Delete file
Delete directory
```

Example endpoints:

```text
GET    /v1/sandboxes/:id/files
GET    /v1/sandboxes/:id/files/content
PUT    /v1/sandboxes/:id/files/content
DELETE /v1/sandboxes/:id/files
```

File operations must operate against the sandbox filesystem.

All paths must be normalized and validated.

The API must never allow host-filesystem traversal.

---

# 27. Resource Limits

Each sandbox must support configurable:

```text
CPU
memory
disk
process count
```

Example defaults:

```text
CPU:        2 vCPU
Memory:     2 GB
Disk:       10 GB
Processes:  512
```

Because all sandboxes run on one VPS, creation/start must fail if insufficient capacity exists.

No scheduler is required.

---

# 28. Networking

Sandboxes should have outbound internet access by default.

They must not be able to directly access:

```text
host services
containerd socket
runtime shim socket
sandboxd internal sockets
cloud metadata service
sensitive private host networks
```

Sandbox-to-sandbox isolation should be maintained by default.

Users may expose ports from a sandbox in a future feature.

---

# 29. Port Exposure

V1 does not require arbitrary public port exposure.

However, the architecture should leave room for:

```text
sandbox port 3000
      ↓
authenticated service proxy
      ↓
public or private sandbox URL
```

Potential future API:

```http
POST /v1/sandboxes/:id/ports
```

This must remain generic.

It should not be browser-specific.

---

# 30. Reconciliation

`sandboxd` and PostgreSQL must periodically reconcile actual runtime state.

Example:

```text
Postgres:
sbx_123 = RUNNING

containerd:
no running task

        ↓

update sandbox state
```

Likewise:

```text
containerd contains unknown sandbox

        ↓

identify orphan
        ↓

clean up or reconcile
```

---

# 31. Sandbox TTL

Every sandbox may have:

```text
expires_at
```

When expiration occurs:

```text
RUNNING/STOPPED
       ↓
DELETING
       ↓
DELETED
```

TTL applies while stopped.

Optional endpoint:

```http
POST /v1/sandboxes/:id/extend
```

---

# 32. Stop vs Expire

These concepts must remain separate.

`stop`:

```text
turn off active compute
preserve writable environment
allow later start
```

`expire`:

```text
permanently destroy sandbox
```

---

# 33. Database Schema

Initial `images` table:

```text
id
name
status
oci_reference
oci_digest
dockerfile
created_at
updated_at
error_message
```

Initial `sandboxes` table:

```text
id
status
image_id
cpu
memory_mb
disk_mb
container_id
snapshot_key
created_at
updated_at
started_at
stopped_at
expires_at
error_message
```

Initial `processes` table:

```text
id
sandbox_id
command
status
exit_code
started_at
completed_at
```

---

# 34. API Authentication

V1 may use API keys.

Example:

```http
Authorization: Bearer sbx_live_xxxxxxxxx
```

The Go runtime shim should listen only on a Unix domain socket.

It must not expose a public TCP interface.

---

# 35. Go Runtime API

The Go runtime adapter should expose a narrow interface.

Conceptually:

```text
Create
Start
Stop
Delete

Exec
Kill

Inspect
Metrics

ImageInspect
ImageImport
ImageDelete
```

Example internal request:

```json
{
  "id": "sbx_abc123",
  "image": "sandbox-images/agent-env@sha256:...",
  "runtime": "io.containerd.runsc.v1",
  "cpu": 2,
  "memory_mb": 2048
}
```

Crystal must not depend directly on containerd-specific structures.

---

# 36. Runtime Abstraction

Crystal should expose an internal abstraction:

```text
Runtime#create
Runtime#start
Runtime#stop
Runtime#delete
Runtime#exec
Runtime#inspect
Runtime#kill
```

Conceptual interface:

```crystal
abstract class Runtime
  abstract def create(config : SandboxConfig) : RuntimeSandbox
  abstract def start(id : String)
  abstract def stop(id : String)
  abstract def delete(id : String)
  abstract def exec(id : String, command : ExecCommand)
  abstract def inspect(id : String) : RuntimeSandbox
end
```

Initial implementation:

```text
ContainerdRuntime
```

---

# 37. Image Builder Abstraction

Crystal should expose:

```text
ImageBuilder#build
ImageBuilder#delete
ImageBuilder#inspect
```

Conceptual interface:

```crystal
abstract class ImageBuilder
  abstract def build(
    dockerfile : String,
    context_path : String?,
    name : String?
  ) : SandboxImage

  abstract def delete(id : String)
end
```

Initial implementation:

```text
BuildKitImageBuilder
```

---

# 38. Logging

Every component should use structured logs.

Example:

```json
{
  "level": "info",
  "event": "sandbox.created",
  "sandbox_id": "sbx_abc123",
  "image_id": "img_xyz789",
  "duration_ms": 731
}
```

Important events:

```text
image.build.started
image.build.completed
image.build.failed
image.deleted

sandbox.create
sandbox.start
sandbox.stop
sandbox.restart
sandbox.delete

process.start
process.exit
process.kill

runtime.error
```

---

# 39. Metrics

Track:

```text
image build duration
image build failures
image disk usage

sandbox creation latency
sandbox start latency
sandbox stop latency

active sandboxes
stopped sandboxes

memory allocated
CPU allocated
disk allocated

command executions
command failures
runtime failures
```

---

# 40. Health Checks

Sandbox service:

```text
GET /health
```

Runtime shim:

```text
GET /health
```

Health checks should verify:

```text
Crystal service running
PostgreSQL reachable
containerd reachable
runtime shim reachable
BuildKit reachable
host disk writable
```

---

# 41. Idempotency

Lifecycle operations should be idempotent where possible.

Examples:

```text
STOPPED → stop → STOPPED

RUNNING → start → RUNNING
```

Deleting an already deleted sandbox must not cause corruption.

---

# 42. Concurrency Control

Only one lifecycle transition may run per sandbox at once.

Prevent simultaneous:

```text
stop
delete
restart
```

for the same sandbox.

Use database locking, optimistic versioning, or equivalent synchronization.

---

# 43. Error Model

API errors should have consistent structure.

Example:

```json
{
  "error": {
    "code": "SANDBOX_NOT_RUNNING",
    "message": "Sandbox sbx_abc123 is currently stopped."
  }
}
```

Potential error codes:

```text
IMAGE_NOT_FOUND
IMAGE_NOT_READY
IMAGE_BUILD_FAILED

SANDBOX_NOT_FOUND
SANDBOX_NOT_RUNNING
SANDBOX_ALREADY_RUNNING
SANDBOX_ALREADY_STOPPED
SANDBOX_START_FAILED
SANDBOX_STOP_FAILED
SANDBOX_CREATE_FAILED
SANDBOX_DELETE_FAILED

INSUFFICIENT_CAPACITY

EXEC_FAILED
EXEC_TIMEOUT

FILE_NOT_FOUND
INVALID_PATH

RUNTIME_ERROR
```

---

# 44. Security Requirements

Sandboxes may execute untrusted or AI-generated code.

Therefore:

* Sandboxes must use gVisor.
* Containers must not run privileged.
* Containerd socket must never be mounted into sandboxes.
* Runtime shim socket must never be mounted into sandboxes.
* Host filesystem must not be exposed.
* Host network namespace must not be used.
* Sensitive host services must be blocked.
* Resource limits must be enforced.
* Unnecessary Linux capabilities must be removed.
* API authentication must be required.
* User-controlled filesystem paths must be normalized and validated.
* Dockerfile builds must not expose host secrets.
* Build workloads must not receive unnecessary host privileges.

---

# 45. Stop/Start Persistence Requirements

The following MUST survive stop/start:

```text
sandbox writable filesystem
files
git repositories
downloaded files
uploaded files
generated artifacts
installed packages
runtime configuration
sandbox ID
image ID
```

The following do NOT need to survive:

```text
running processes
RAM
open TCP connections
active WebSocket connections
shell sessions
process IDs
in-memory application state
```

Example:

```text
Before stop:

Node server running
npm packages installed
repository cloned
files generated

After start:

Node process is gone

npm packages remain installed
repository still exists
generated files still exist
```

---

# 46. Sandbox Startup Semantics

Starting a sandbox means starting the sandbox environment.

It does NOT recreate previously running processes automatically.

Example:

```text
before stop:
npm run dev

after start:
npm run dev is NOT automatically restarted
```

Users are responsible for restarting application processes as necessary.

---

# 47. Image vs Sandbox State

The platform must clearly distinguish:

Image:

```text
immutable reusable template
```

Sandbox:

```text
mutable instance created from image
```

Example:

```text
Dockerfile
    ↓
img_python
    ↓
    ├── sbx_001
    ├── sbx_002
    └── sbx_003
```

Changes inside `sbx_001` do not modify:

```text
img_python
sbx_002
sbx_003
```

---

# 48. Repository Structure

Suggested monorepo:

```text
sandbox/
├── src/
│   ├── api/
│   ├── sandbox/
│   ├── images/
│   ├── files/
│   ├── processes/
│   ├── runtime/
│   └── database/
│
├── services/
│   └── containerd-runtime/
│       └── Go containerd adapter
│
├── migrations/
│
├── infra/
│   ├── buildkit/
│   ├── containerd/
│   └── gvisor/
│
└── docs/
```

The Crystal API and `sandboxd` may initially live in the same process.

---

# 49. Initial Implementation Phases

## Phase 1 — Runtime

Implement:

```text
Crystal service
Go containerd adapter
containerd
gVisor
```

Required operations:

```text
create
start
stop
delete
exec
```

Success criteria:

A container can be created from an existing OCI image, commands can be executed, it can be stopped and restarted, and filesystem state remains intact.

---

## Phase 2 — Image Building

Implement:

```text
Dockerfile API
BuildKit integration
build context upload
image metadata
containerd image import
image deletion
```

Success criteria:

```text
send Dockerfile
      ↓
receive image ID
      ↓
create sandbox from image ID
```

---

## Phase 3 — File and Process APIs

Implement:

```text
file read/write
file upload/download
directory operations
process listing
process kill
long-running process support
```

Success criteria:

A client can use a sandbox as a generic remote execution environment without any workload-specific APIs.

---

## Phase 4 — Reliability

Implement:

```text
reconciliation
orphan cleanup
structured logging
metrics
lifecycle locking
request idempotency
TTL cleanup
```

---

## Phase 5 — Resource Enforcement and Secure Networking

Implement:

* Enforce each sandbox's `disk_mb` writable-storage limit with XFS project quotas, covering overlay upper/work directories and stopped file API writes.
* Reserve CPU, memory and disk in PostgreSQL before create/start/restart; serialize admission with lifecycle intent across API processes.
* Enable IPv4 internet access with public DNS, per-sandbox routed network namespaces, NAT and fail-closed firewall rules.
* Block host services (including host public IPs), private/special-use networks, cloud metadata, unsolicited ingress, IPv6 and other sandboxes.
* Recover reservations, quotas and network ownership after API/adapter crashes, partial setup and interrupted cleanup.

Success criteria:

Sandboxes download packages, cannot reach protected destinations, cannot exceed their resource limits, and release capacity after confirmed cleanup. Stop releases CPU/memory and networking while preserving disk and its reservation. Delete and expiration release disk only after physical snapshot reclamation. Concurrent admission and crash recovery must not overcommit capacity or leave unprotected networking.

Implementation and deployment requirements: [Resource enforcement and secure networking](docs/resources-networking.md). Acceptance suite: `make integration-resources`; PostgreSQL race/fault tests and an optional real XFS quota test run with `make test`.

---

# 50. V1 Definition of Done

V1 is complete when this workflow works reliably:

```text
1. User submits Dockerfile

2. Platform builds image

3. Image becomes READY

4. User receives image ID

5. POST /sandboxes using image ID

6. Sandbox becomes RUNNING

7. Execute arbitrary commands

8. Create and modify files

9. Install additional software inside sandbox

10. Start arbitrary long-running processes

11. POST /sandboxes/:id/stop

12. Sandbox becomes STOPPED

13. Wait arbitrary amount of time

14. POST /sandboxes/:id/start

15. Sandbox becomes RUNNING

16. Installed packages still exist

17. Previously created files still exist

18. Previous processes are no longer running

19. Execute additional commands

20. DELETE /sandboxes/:id

21. Sandbox-specific state is permanently removed

22. Original image remains available for future sandboxes
```

---

# 51. Core Design Principles

## Crystal owns the product

All meaningful platform logic lives in Crystal:

```text
API
sandbox lifecycle
image lifecycle
filesystem logic
process management
state management
TTL
reconciliation
metrics
```

Go exists only as a thin compatibility layer for containerd.

---

## Dockerfiles define environments

The sandbox service should not decide what software the user needs.

```text
Dockerfile
    ↓
reusable image
    ↓
sandbox
```

Anything the workload requires should be installed by the image.

---

## The runtime is workload-agnostic

The platform should not know whether the user is running:

```text
an AI agent
Chromium
a compiler
a web server
a database
a CLI program
a Python script
```

They are all just processes inside a sandbox.

---

## Build once, launch many

```text
Dockerfile
    ↓
build once
    ↓
img_abc
    ↓
create sandbox
create sandbox
create sandbox
```

Sandbox creation must not rebuild the environment.

---

## Keep containerd behind an abstraction

No application code outside the runtime adapter should depend on containerd internals.

The system should think in terms of:

```text
Sandbox
Image
Runtime
Process
File
```

---

## Stop is not delete

```text
STOP
=
stop active processes
keep mutable environment

DELETE
=
destroy mutable environment
```

---

## Images are immutable

A sandbox may change after creation.

The image it originated from does not.

If a different base environment is needed, build a new image.

---

## Optimize for one VPS first

Initial architecture:

```text
one VPS
one Crystal service
one containerd instance
one BuildKit instance
one PostgreSQL database
gVisor
local image storage
local sandbox snapshots
small Go adapter
```

Do not introduce distributed infrastructure until it is actually required.

