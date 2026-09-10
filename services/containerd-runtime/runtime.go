package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/containerd/containerd/api/services/tasks/v1"
	runtimeoptions "github.com/containerd/containerd/api/types/runtimeoptions/v1"
	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/containers"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/containerd/errdefs"
	specs "github.com/opencontainers/runtime-spec/specs-go"
)

const runtimeName = "io.containerd.runsc.v1"
const ownerLabel = "sandcube.managed"

type Config struct {
	ID       string   `json:"id"`
	Image    string   `json:"image"`
	Command  []string `json:"command"`
	CPU      int64    `json:"cpu"`
	MemoryMB int64    `json:"memory_mb"`
	Pids     int64    `json:"pids"`
}
type Sandbox struct {
	ID       string `json:"id"`
	Status   string `json:"status"`
	Snapshot string `json:"snapshot_key"`
}
type ExecRequest struct {
	Command []string          `json:"command"`
	Cwd     string            `json:"cwd"`
	Env     map[string]string `json:"env"`
	Timeout int               `json:"timeout_seconds"`
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
	client     *containerd.Client
	namespace  string
	configPath string
	buildRoot  string
	imageMu    sync.Mutex
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
	img, err := r.client.GetImage(ctx, cfg.Image)
	if err != nil {
		return Sandbox{}, err
	}
	// Images must already be unpacked by the operator. No registry credentials or pulls here.
	snapshotCreated := false
	_, err = r.client.NewContainer(ctx, cfg.ID,
		containerd.WithImage(img), containerd.WithSnapshotter("overlayfs"),
		containerd.WithRuntime(runtimeName, &runtimeoptions.Options{ConfigPath: r.configPath}),
		containerd.WithContainerLabels(map[string]string{ownerLabel: "true"}),
		func(ctx context.Context, client *containerd.Client, c *containers.Container) error {
			err := containerd.WithNewSnapshot(cfg.ID, img)(ctx, client, c)
			snapshotCreated = err == nil
			return err
		},
		containerd.WithNewSpec(oci.WithImageConfig(img), oci.WithProcessArgs(cfg.Command...),
			// runsc shim requires explicit sandbox identity to wire init IO correctly.
			oci.WithAnnotations(map[string]string{"io.kubernetes.cri.container-type": "sandbox", "io.kubernetes.cri.sandbox-id": cfg.ID}),
			oci.WithMemoryLimit(uint64(cfg.MemoryMB)*1024*1024), oci.WithCPUCFS(cfg.CPU*100000, 100000),
			oci.WithPidsLimit(cfg.Pids), oci.WithCapabilities([]string{}), oci.WithNoNewPrivileges,
			oci.WithLinuxNamespace(specs.LinuxNamespace{Type: specs.NetworkNamespace}),
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
		return r.describe(ctx, c)
	}
	if err != nil {
		return Sandbox{}, err
	}
	// Delete only the task. The container and its writable snapshot are retained.
	if err = r.deleteTask(ctx, t); err != nil {
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
		return nil
	}
	if err != nil {
		return err
	}
	if _, err = r.Stop(ctx, id); err != nil {
		return err
	}
	return c.Delete(ctx, containerd.WithSnapshotCleanup)
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
	ctx = r.ctx(ctx)
	c, err := r.load(ctx, id)
	if err != nil {
		return ExecResult{}, err
	}
	t, err := c.Task(ctx, nil)
	if errdefs.IsNotFound(err) {
		return ExecResult{}, errdefs.ErrFailedPrecondition
	}
	if err != nil {
		return ExecResult{}, err
	}
	s, err := c.Spec(ctx)
	if err != nil {
		return ExecResult{}, err
	}
	p := *s.Process
	p.Args = req.Command
	p.Terminal = false
	if req.Cwd != "" {
		p.Cwd = req.Cwd
	}
	p.Env = mergeEnv(p.Env, req.Env)
	var out, stderr limitedBuffer
	proc, err := t.Exec(ctx, fmt.Sprintf("exec-%d", time.Now().UnixNano()), &p, cio.NewCreator(cio.WithStreams(nil, &out, &stderr)))
	if err != nil {
		return ExecResult{}, err
	}
	defer func() {
		clean, cancel := context.WithTimeout(r.ctx(context.Background()), 10*time.Second)
		defer cancel()
		status, statusErr := proc.Status(clean)
		if statusErr == nil {
			if status.Status == containerd.Running {
				_, _ = proc.Delete(clean, containerd.WithProcessKill)
			} else {
				_, _ = proc.Delete(clean)
			}
		}
	}()
	wait, err := proc.Wait(ctx)
	if err != nil {
		return ExecResult{}, err
	}
	if err = proc.Start(ctx); err != nil {
		return ExecResult{}, err
	}
	timer := time.NewTimer(time.Duration(req.Timeout) * time.Second)
	defer timer.Stop()
	result := ExecResult{}
	var status containerd.ExitStatus
	select {
	case status = <-wait:
	case <-timer.C:
		result.TimedOut = true
		if err = proc.Kill(ctx, syscall.SIGKILL); err != nil && !errdefs.IsNotFound(err) {
			return result, err
		}
		select {
		case status = <-wait:
		case <-time.After(10 * time.Second):
			return result, errors.New("timed out waiting for killed process")
		case <-ctx.Done():
			return result, ctx.Err()
		}
	case <-ctx.Done():
		return result, ctx.Err()
	}
	code, _, err := status.Result()
	if err != nil {
		return result, err
	}
	result.ExitCode = code
	// Delete waits for the IO copier to finish, so final output is included.
	if _, err = proc.Delete(ctx); err != nil {
		return result, err
	}
	var a, b bool
	result.Stdout, a = out.result()
	result.Stderr, b = stderr.result()
	result.Truncated = a || b
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
