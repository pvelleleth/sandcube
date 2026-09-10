package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"crypto/sha256"
	"encoding/json"
	"github.com/containerd/containerd/api/services/tasks/v1"
	runtimeoptions "github.com/containerd/containerd/api/types/runtimeoptions/v1"
	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/containers"
	"github.com/containerd/containerd/v2/core/snapshots"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/containerd/errdefs"
	specs "github.com/opencontainers/runtime-spec/specs-go"
	"os"
	"path/filepath"
)

const runtimeName = "io.containerd.runsc.v1"
const ownerLabel = "sandcube.managed"

type Config struct {
	ID       string   `json:"id"`
	Image    string   `json:"image"`
	Command  []string `json:"command"`
	CPU      int64    `json:"cpu"`
	DiskMB   int64    `json:"disk_mb"`
	MemoryMB int64    `json:"memory_mb"`
	Pids     int64    `json:"pids"`
}
type Sandbox struct {
	ID       string `json:"id"`
	Status   string `json:"status"`
	Snapshot string `json:"snapshot_key"`
}
type ExecRequest struct {
	RequestID string            `json:"request_id,omitempty"`
	Command   []string          `json:"command"`
	Cwd       string            `json:"cwd"`
	Env       map[string]string `json:"env"`
	Timeout   int               `json:"timeout_seconds"`
}
type ExecResult struct {
	Stdout    string `json:"stdout"`
	Stderr    string `json:"stderr"`
	ExitCode  uint32 `json:"exit_code"`
	TimedOut  bool   `json:"timed_out"`
	Truncated bool   `json:"truncated"`
}
type Backend interface {
	Health(context.Context) error
	Create(context.Context, Config) (Sandbox, error)
	Start(context.Context, string) (Sandbox, error)
	Stop(context.Context, string) (Sandbox, error)
	Delete(context.Context, string) error
	Inspect(context.Context, string) (Sandbox, error)
	Exec(context.Context, string, ExecRequest) (ExecResult, error)
}
type Runtime struct {
	client      *containerd.Client
	namespace   string
	configPath  string
	buildRoot   string
	stateRoot   string
	historyRoot string
	imageMu     sync.Mutex
	processMu   sync.Mutex
	processes   map[string]*trackedProcess
}

func (r *Runtime) ctx(ctx context.Context) context.Context {
	return namespaces.WithNamespace(ctx, r.namespace)
}
func (r *Runtime) Health(ctx context.Context) error {
	_, err := r.client.Version(r.ctx(ctx))
	return err
}
func (r *Runtime) load(ctx context.Context, id string) (containerd.Container, error) {
	c, err := r.client.LoadContainer(ctx, id)
	if err != nil {
		return nil, err
	}
	info, err := c.Info(ctx)
	if err != nil {
		return nil, err
	}
	if info.Labels[ownerLabel] != "true" || info.Runtime.Name != runtimeName {
		return nil, fmt.Errorf("unmanaged container: %w", errdefs.ErrNotFound)
	}
	return c, nil
}
func (r *Runtime) Create(ctx context.Context, cfg Config) (Sandbox, error) {
	r.imageMu.Lock()
	defer r.imageMu.Unlock()
	ctx = r.ctx(ctx)
	encoded, _ := json.Marshal(cfg)
	fingerprint := fmt.Sprintf("%x", sha256.Sum256(encoded))
	if existing, e := r.load(ctx, cfg.ID); e == nil {
		info, e := existing.Info(ctx)
		if e != nil {
			return Sandbox{}, e
		}
		if info.Labels["sandcube.config"] != fingerprint {
			return Sandbox{}, errdefs.ErrAlreadyExists
		}
		return r.describe(ctx, existing)
	} else if !errdefs.IsNotFound(e) {
		return Sandbox{}, e
	}
	// An ID collision with an unmanaged container is not an orphan snapshot.
	if _, e := r.client.LoadContainer(ctx, cfg.ID); e == nil {
		return Sandbox{}, errdefs.ErrAlreadyExists
	} else if !errdefs.IsNotFound(e) {
		return Sandbox{}, e
	}
	// Recover a labelled snapshot left between snapshot prepare and container commit.
	if info, e := r.client.SnapshotService("overlayfs").Stat(ctx, cfg.ID); e == nil && info.Labels[ownerLabel] == "true" {
		if e = r.client.SnapshotService("overlayfs").Remove(ctx, cfg.ID); e != nil {
			return Sandbox{}, e
		}
	} else if e != nil && !errdefs.IsNotFound(e) {
		return Sandbox{}, e
	}
	if err := r.reclaimQuota(ctx, cfg.ID); err != nil {
		return Sandbox{}, err
	}
	img, err := r.client.GetImage(ctx, cfg.Image)
	if err != nil {
		return Sandbox{}, err
	}
	// Images must already be unpacked by the operator. No registry credentials or pulls here.
	snapshotCreated := false
	_, err = r.client.NewContainer(ctx, cfg.ID,
		containerd.WithImage(img), containerd.WithSnapshotter("overlayfs"),
		containerd.WithRuntime(runtimeName, &runtimeoptions.Options{ConfigPath: r.configPath}),
		containerd.WithContainerLabels(map[string]string{ownerLabel: "true", "sandcube.config": fingerprint, "sandcube.disk_mb": strconv.FormatInt(cfg.DiskMB, 10)}),
		func(ctx context.Context, client *containerd.Client, c *containers.Container) error {
			err := containerd.WithNewSnapshot(cfg.ID, img, snapshots.WithLabels(map[string]string{ownerLabel: "true"}))(ctx, client, c)
			snapshotCreated = err == nil
			if err != nil {
				return err
			}
			ms, err := client.SnapshotService("overlayfs").Mounts(ctx, cfg.ID)
			if err != nil {
				return err
			}
			return r.prepareQuota(ctx, cfg.ID, cfg.DiskMB, ms)
		},
		containerd.WithNewSpec(oci.WithImageConfig(img), oci.WithProcessArgs(cfg.Command...),
			// runsc shim requires explicit sandbox identity to wire init IO correctly.
			oci.WithAnnotations(map[string]string{"io.kubernetes.cri.container-type": "sandbox", "io.kubernetes.cri.sandbox-id": cfg.ID}),
			oci.WithMemoryLimit(uint64(cfg.MemoryMB)*1024*1024), oci.WithMemorySwap(cfg.MemoryMB*1024*1024), oci.WithCPUCFS(cfg.CPU*100000, 100000),
			oci.WithMounts([]specs.Mount{{Destination: "/etc/resolv.conf", Type: "bind", Source: r.resolverPath(cfg.ID), Options: []string{"bind", "ro", "nosuid", "nodev", "noexec"}}}),
			withOOMGroup, oci.WithPidsLimit(cfg.Pids), oci.WithCapabilities([]string{}), oci.WithNoNewPrivileges,
			oci.WithLinuxNamespace(specs.LinuxNamespace{Type: specs.NetworkNamespace, Path: r.networkPath(cfg.ID)}),
		),
	)
	if err != nil {
		if snapshotCreated {
			cleanup, cancel := context.WithTimeout(r.ctx(context.Background()), 10*time.Second)
			defer cancel()
			cleanupErr := r.client.SnapshotService("overlayfs").Remove(cleanup, cfg.ID)
			if cleanupErr != nil && !errdefs.IsNotFound(cleanupErr) {
				err = errors.Join(err, fmt.Errorf("snapshot rollback: %w", cleanupErr))
			}
		}
		return Sandbox{}, err
	}
	return Sandbox{ID: cfg.ID, Status: "stopped", Snapshot: cfg.ID}, nil
}
func (r *Runtime) describe(ctx context.Context, c containerd.Container) (Sandbox, error) {
	info, err := c.Info(ctx)
	if err != nil {
		return Sandbox{}, err
	}
	result := Sandbox{ID: c.ID(), Status: "stopped", Snapshot: info.SnapshotKey}
	t, err := c.Task(ctx, nil)
	if errdefs.IsNotFound(err) {
		return result, nil
	}
	if err != nil {
		return result, err
	}
	s, err := t.Status(ctx)
	if err != nil {
		return result, err
	}
	if s.Status == containerd.Running {
		result.Status = "running"
	}
	return result, nil
}
func (r *Runtime) Inspect(ctx context.Context, id string) (Sandbox, error) {
	ctx = r.ctx(ctx)
	c, e := r.load(ctx, id)
	if e != nil {
		return Sandbox{}, e
	}
	return r.describe(ctx, c)
}
func (r *Runtime) Start(ctx context.Context, id string) (Sandbox, error) {
	ctx = r.ctx(ctx)
	c, err := r.load(ctx, id)
	if err != nil {
		return Sandbox{}, err
	}
	t, err := c.Task(ctx, nil)
	if err == nil {
		s, e := t.Status(ctx)
		if e != nil {
			return Sandbox{}, e
		}
		if s.Status == containerd.Running {
			return r.describe(ctx, c)
		}
		if e = r.deleteTask(ctx, t); e != nil {
			return Sandbox{}, e
		}
	} else if !errdefs.IsNotFound(err) {
		return Sandbox{}, err
	}
	if err = r.checkQuota(ctx, id); err != nil {
		return Sandbox{}, err
	}
	if err = r.setupNetwork(ctx, id); err != nil {
		return Sandbox{}, err
	}
	t, err = c.NewTask(ctx, cio.NullIO)
	if err != nil {
		return Sandbox{}, err
	}
	if err = t.Start(ctx); err != nil {
		cleanup, cancel := context.WithTimeout(r.ctx(context.Background()), 10*time.Second)
		defer cancel()
		if cleanupErr := r.deleteTask(cleanup, t); cleanupErr != nil {
			err = errors.Join(err, fmt.Errorf("task rollback: %w", cleanupErr))
		}
		return Sandbox{}, err
	}
	return r.describe(ctx, c)
}
func (r *Runtime) Stop(ctx context.Context, id string) (Sandbox, error) {
	ctx = r.ctx(ctx)
	c, err := r.load(ctx, id)
	if err != nil {
		return Sandbox{}, err
	}
	t, err := c.Task(ctx, nil)
	if errdefs.IsNotFound(err) {
		if err = r.removeNetwork(ctx, id); err != nil {
			return Sandbox{}, err
		}
		return r.describe(ctx, c)
	}
	if err != nil {
		return Sandbox{}, err
	}
	r.processMu.Lock()
	ps := []*trackedProcess{}
	for _, p := range r.processes {
		if p.info.SandboxID == id {
			ps = append(ps, p)
		}
	}
	r.processMu.Unlock()
	for _, p := range ps {
		if p.snapshot().Status == "running" {
			if e := p.proc.Kill(ctx, syscall.SIGKILL); e != nil && !errdefs.IsNotFound(e) {
				return Sandbox{}, e
			}
		}
	}
	if err = r.settleProcesses(ctx, id); err != nil {
		return Sandbox{}, err
	}
	// Delete only the task. The container and its writable snapshot are retained.
	if err = r.deleteTask(ctx, t); err != nil {
		return Sandbox{}, err
	}
	if err = r.settleProcesses(ctx, id); err != nil {
		return Sandbox{}, err
	}
	if err = r.removeNetwork(ctx, id); err != nil {
		return Sandbox{}, err
	}
	return r.describe(ctx, c)
}

// Failed starts have no process-exit event. Waiting for one deadlocks cleanup.
// The task service permits deleting Created tasks; the high-level SDK assumes runc
// and disallows Created tasks with a PID, so use its underlying official API here.
func (r *Runtime) deleteTask(ctx context.Context, task containerd.Task) error {
	status, err := task.Status(ctx)
	if errdefs.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if status.Status == containerd.Running || status.Status == containerd.Paused || status.Status == containerd.Pausing {
		_, err = task.Delete(ctx, containerd.WithProcessKill)
	} else {
		_, err = r.client.TaskService().Delete(ctx, &tasks.DeleteTaskRequest{ContainerID: task.ID()})
		if err == nil && task.IO() != nil {
			task.IO().Cancel()
			task.IO().Wait()
			task.IO().Close()
		}
	}
	if errdefs.IsNotFound(err) {
		return nil
	}
	return err
}
func (r *Runtime) Delete(ctx context.Context, id string) error {
	ctx = r.ctx(ctx)
	c, err := r.load(ctx, id)
	if errdefs.IsNotFound(err) {
		if _, e := r.client.LoadContainer(ctx, id); e == nil {
			return errdefs.ErrNotFound
		} else if !errdefs.IsNotFound(e) {
			return e
		}
		if info, e := r.client.SnapshotService("overlayfs").Stat(ctx, id); e == nil && info.Labels[ownerLabel] == "true" {
			if e = r.client.SnapshotService("overlayfs").Remove(ctx, id); e != nil && !errdefs.IsNotFound(e) {
				return e
			}
		} else if e != nil && !errdefs.IsNotFound(e) {
			return e
		}
		if err = r.reclaimQuota(ctx, id); err != nil {
			return err
		}
		if err = r.settleProcesses(ctx, id); err != nil {
			return err
		}
		if err = r.removeNetwork(ctx, id); err != nil {
			return err
		}
		return r.forgetProcesses(id)
	}
	if err != nil {
		return err
	}
	if _, err = r.Stop(ctx, id); err != nil {
		return err
	}
	if err = c.Delete(ctx, containerd.WithSnapshotCleanup); err != nil {
		return err
	}
	if err = r.reclaimQuota(ctx, id); err != nil {
		return err
	}
	return r.forgetProcesses(id)
}

// Cap captured output while continuing to drain pipes, avoiding deadlocks and unbounded memory.
type limitedBuffer struct {
	mu        sync.Mutex
	b         bytes.Buffer
	truncated bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(p)
	left := 1024*1024 - b.b.Len()
	if len(p) > left {
		p = p[:left]
		b.truncated = true
	}
	_, _ = b.b.Write(p)
	return n, nil
}
func (b *limitedBuffer) result() (string, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String(), b.truncated
}
func (r *Runtime) Exec(ctx context.Context, id string, req ExecRequest) (ExecResult, error) {
	wait, err := r.PrepareExec(ctx, id, req)
	if err != nil {
		return ExecResult{}, err
	}
	return wait()
}
func (r *Runtime) PrepareExec(ctx context.Context, id string, req ExecRequest) (func() (ExecResult, error), error) {
	info, err := r.StartProcess(ctx, id, req)
	if err != nil {
		return nil, err
	}
	p, err := r.lookupProcess(id, info.ID)
	if err != nil {
		return nil, err
	}
	return func() (ExecResult, error) { return r.waitExec(ctx, id, req, p) }, nil
}
func (r *Runtime) waitExec(ctx context.Context, id string, req ExecRequest, p *trackedProcess) (ExecResult, error) {
	info := p.snapshot()
	timer := time.NewTimer(time.Duration(req.Timeout) * time.Second)
	defer timer.Stop()
	result := ExecResult{}
	select {
	case <-p.done:
	case <-timer.C:
		result.TimedOut = true
		p.mu.Lock()
		p.info.TimedOut = true
		p.mu.Unlock()
		_, err := r.KillProcess(ctx, id, info.ID)
		if err != nil {
			return result, err
		}
	case <-ctx.Done():
		return result, ctx.Err()
	}
	info = p.snapshot()
	result.TimedOut = result.TimedOut || info.TimedOut
	if info.ExitCode == nil {
		return result, errors.New(info.Error)
	}
	result.ExitCode = *info.ExitCode
	if r.historyRoot != "" {
		dir := r.processDir(id, info.ID)
		out, e := os.ReadFile(filepath.Join(dir, "stdout"))
		if e != nil {
			return result, e
		}
		stderr, e := os.ReadFile(filepath.Join(dir, "stderr"))
		if e != nil {
			return result, e
		}
		result.Stdout = string(out)
		result.Stderr = string(stderr)
		_, a := os.Stat(filepath.Join(dir, "stdout.truncated"))
		_, b := os.Stat(filepath.Join(dir, "stderr.truncated"))
		result.Truncated = a == nil || b == nil
	} else {
		var a, b bool
		result.Stdout, a = p.out.result()
		result.Stderr, b = p.stderr.result()
		result.Truncated = a || b
	}
	return result, nil
}

func mergeEnv(base []string, overrides map[string]string) []string {
	values := map[string]string{}
	for _, entry := range base {
		key, value, ok := strings.Cut(entry, "=")
		if ok {
			values[key] = value
		}
	}
	for key, value := range overrides {
		values[key] = value
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]string, 0, len(keys))
	for _, key := range keys {
		result = append(result, key+"="+values[key])
	}
	return result
}

// Kill the whole task cgroup on OOM. Killing only a gofer/helper can leave a
// nominally running sandbox with a broken filesystem and retained compute.
func withOOMGroup(_ context.Context, _ oci.Client, _ *containers.Container, spec *specs.Spec) error {
	spec.Linux.Resources.Unified = map[string]string{"memory.oom.group": "1"}
	return nil
}
