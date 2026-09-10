package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"sync"
	"syscall"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/errdefs"
)

type ProcessInfo struct {
	ID          string     `json:"id"`
	SandboxID   string     `json:"sandbox_id"`
	Command     []string   `json:"command"`
	Status      string     `json:"status"`
	ExitCode    *uint32    `json:"exit_code"`
	StartedAt   time.Time  `json:"started_at"`
	CompletedAt *time.Time `json:"completed_at"`
	Error       string     `json:"error,omitempty"`
}
type trackedProcess struct {
	mu          sync.Mutex
	info        ProcessInfo
	proc        containerd.Process
	out, stderr limitedBuffer
	done        chan struct{}
}
type ProcessBackend interface {
	StartProcess(context.Context, string, ExecRequest) (ProcessInfo, error)
	Processes(context.Context, string) ([]ProcessInfo, error)
	Process(context.Context, string, string) (ProcessInfo, error)
	ProcessLogs(context.Context, string, string) (any, error)
	KillProcess(context.Context, string, string) (ProcessInfo, error)
}

func newProcessID() string {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	return "proc_" + hex.EncodeToString(b[:])
}
func (p *trackedProcess) snapshot() ProcessInfo { p.mu.Lock(); defer p.mu.Unlock(); return p.info }
func (r *Runtime) lookupProcess(id, pid string) (*trackedProcess, error) {
	r.processMu.Lock()
	defer r.processMu.Unlock()
	p := r.processes[pid]
	if p == nil || p.info.SandboxID != id {
		return nil, errdefs.ErrNotFound
	}
	return p, nil
}
func (r *Runtime) StartProcess(ctx context.Context, id string, req ExecRequest) (ProcessInfo, error) {
	ctx = r.ctx(ctx)
	c, err := r.load(ctx, id)
	if err != nil {
		return ProcessInfo{}, err
	}
	t, err := c.Task(ctx, nil)
	if errdefs.IsNotFound(err) {
		return ProcessInfo{}, errdefs.ErrFailedPrecondition
	}
	if err != nil {
		return ProcessInfo{}, err
	}
	status, err := t.Status(ctx)
	if err != nil {
		return ProcessInfo{}, err
	}
	if status.Status != containerd.Running {
		return ProcessInfo{}, errdefs.ErrFailedPrecondition
	}
	spec, err := c.Spec(ctx)
	if err != nil {
		return ProcessInfo{}, err
	}
	p := &trackedProcess{info: ProcessInfo{ID: newProcessID(), SandboxID: id, Command: req.Command, Status: "running", StartedAt: time.Now().UTC()}, done: make(chan struct{})}
	r.processMu.Lock()
	if r.processes == nil {
		r.processes = make(map[string]*trackedProcess)
	}
	if len(r.processes) >= 128 {
		r.processMu.Unlock()
		return ProcessInfo{}, fmt.Errorf("process history limit reached; delete an unused sandbox: %w", errdefs.ErrResourceExhausted)
	}
	r.processes[p.info.ID] = p
	r.processMu.Unlock()
	success := false
	defer func() {
		if !success {
			r.processMu.Lock()
			delete(r.processes, p.info.ID)
			r.processMu.Unlock()
		}
	}()
	ps := *spec.Process
	ps.Args = req.Command
	ps.Terminal = false
	ps.Env = mergeEnv(ps.Env, req.Env)
	if req.Cwd != "" {
		ps.Cwd = req.Cwd
	}
	// IO and Wait must outlive the initiating HTTP request, including disconnect.
	background, cancel := context.WithCancel(r.ctx(context.Background()))
	proc, err := t.Exec(background, p.info.ID, &ps, cio.NewCreator(cio.WithStreams(nil, &p.out, &p.stderr)))
	if err != nil {
		cancel()
		return ProcessInfo{}, err
	}
	p.proc = proc
	wait, err := proc.Wait(background)
	if err == nil {
		err = proc.Start(ctx)
	}
	if err != nil {
		clean, stop := context.WithTimeout(r.ctx(context.Background()), 10*time.Second)
		defer stop()
		state, statusErr := proc.Status(clean)
		if statusErr == nil && state.Status == containerd.Running {
			_, _ = proc.Delete(clean, containerd.WithProcessKill)
		} else {
			_, _ = proc.Delete(clean)
		}
		if proc.IO() != nil {
			proc.IO().Cancel()
			proc.IO().Wait()
			_ = proc.IO().Close()
		}
		cancel()
		return ProcessInfo{}, err
	}
	success = true
	go func() {
		defer cancel()
		defer close(p.done)
		exit := <-wait
		code, at, waitErr := exit.Result()
		clean, stop := context.WithTimeout(r.ctx(context.Background()), 15*time.Second)
		defer stop()
		// Delete waits for final IO. Stop may already have removed the exec.
		_, delErr := proc.Delete(clean)
		if delErr != nil && proc.IO() != nil {
			proc.IO().Cancel()
			proc.IO().Wait()
			_ = proc.IO().Close()
		}
		p.mu.Lock()
		defer p.mu.Unlock()
		if waitErr != nil {
			p.info.Status = "error"
			p.info.Error = waitErr.Error()
		} else {
			p.info.Status = "exited"
			p.info.ExitCode = &code
		}
		if delErr != nil && !errdefs.IsNotFound(delErr) {
			p.info.Error = delErr.Error()
		}
		if at.IsZero() {
			at = time.Now().UTC()
		}
		p.info.CompletedAt = &at
	}()
	return p.snapshot(), nil
}
func (r *Runtime) Processes(ctx context.Context, id string) ([]ProcessInfo, error) {
	if _, err := r.load(r.ctx(ctx), id); err != nil {
		return nil, err
	}
	r.processMu.Lock()
	ps := make([]*trackedProcess, 0)
	for _, p := range r.processes {
		if p.info.SandboxID == id {
			ps = append(ps, p)
		}
	}
	r.processMu.Unlock()
	result := make([]ProcessInfo, 0, len(ps))
	for _, p := range ps {
		result = append(result, p.snapshot())
	}
	sort.Slice(result, func(i, j int) bool { return result[i].StartedAt.Before(result[j].StartedAt) })
	return result, nil
}
func (r *Runtime) Process(ctx context.Context, id, pid string) (ProcessInfo, error) {
	if _, err := r.load(r.ctx(ctx), id); err != nil {
		return ProcessInfo{}, err
	}
	p, err := r.lookupProcess(id, pid)
	if err != nil {
		return ProcessInfo{}, err
	}
	return p.snapshot(), nil
}
func (r *Runtime) ProcessLogs(ctx context.Context, id, pid string) (any, error) {
	if _, err := r.Process(ctx, id, pid); err != nil {
		return nil, err
	}
	p, err := r.lookupProcess(id, pid)
	if err != nil {
		return nil, err
	}
	out, a := p.out.result()
	stderr, b := p.stderr.result()
	return map[string]any{"stdout": out, "stderr": stderr, "truncated": a || b}, nil
}
func (r *Runtime) KillProcess(ctx context.Context, id, pid string) (ProcessInfo, error) {
	if _, err := r.Process(ctx, id, pid); err != nil {
		return ProcessInfo{}, err
	}
	p, err := r.lookupProcess(id, pid)
	if err != nil {
		return ProcessInfo{}, err
	}
	if p.snapshot().Status != "running" {
		return p.snapshot(), nil
	}
	if err = p.proc.Kill(r.ctx(ctx), syscall.SIGKILL); err != nil && !errdefs.IsNotFound(err) {
		return ProcessInfo{}, err
	}
	select {
	case <-p.done:
		return p.snapshot(), nil
	case <-ctx.Done():
		return ProcessInfo{}, ctx.Err()
	}
}

// Called under the same lifecycle lock as process creation, after task teardown.
func (r *Runtime) settleProcesses(ctx context.Context, id string) error {
	r.processMu.Lock()
	ps := make([]*trackedProcess, 0)
	for _, p := range r.processes {
		if p.info.SandboxID == id {
			ps = append(ps, p)
		}
	}
	r.processMu.Unlock()
	for _, p := range ps {
		select {
		case <-p.done:
		case <-ctx.Done():
			return errors.New("waiting for sandbox processes to stop: " + ctx.Err().Error())
		}
	}
	return nil
}
func (r *Runtime) forgetProcesses(id string) {
	r.processMu.Lock()
	defer r.processMu.Unlock()
	for pid, p := range r.processes {
		if p.info.SandboxID == id {
			delete(r.processes, pid)
		}
	}
}
