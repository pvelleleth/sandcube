package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"sync"
	"syscall"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/errdefs"
)

var validProcessID = regexp.MustCompile(`^proc_[a-f0-9]{32}$`)

type ProcessInfo struct {
	RequestHash string     `json:"request_hash,omitempty"`
	Timeout     int        `json:"timeout_seconds,omitempty"`
	TimedOut    bool       `json:"timed_out"`
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
	encoded, _ := json.Marshal(req)
	fingerprint := fmt.Sprintf("%x", sha256.Sum256(encoded))
	if req.RequestID != "" {
		if !validProcessID.MatchString(req.RequestID) {
			return ProcessInfo{}, errdefs.ErrInvalidArgument
		}
		if existing, e := r.lookupProcess(id, req.RequestID); e == nil {
			info := existing.snapshot()
			if info.RequestHash != fingerprint {
				return ProcessInfo{}, errdefs.ErrAlreadyExists
			}
			return info, nil
		}
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
	p := &trackedProcess{info: ProcessInfo{ID: newProcessID(), SandboxID: id, Command: req.Command, Status: "starting", StartedAt: time.Now().UTC()}, done: make(chan struct{})}
	p.info.RequestHash = fingerprint
	p.info.Timeout = req.Timeout
	if req.RequestID != "" {
		p.info.ID = req.RequestID
	}
	r.processMu.Lock()
	if r.processes == nil {
		r.processes = make(map[string]*trackedProcess)
	}
	r.processes[p.info.ID] = p
	r.processMu.Unlock()
	success := false
	defer func() {
		if !success {
			p.mu.Lock()
			p.info.Status = "error"
			p.info.Error = "Process start failed"
			at := time.Now().UTC()
			p.info.CompletedAt = &at
			if e := r.saveProcess(p); e != nil {
				slog.Error("process.persist.failed", "error", e)
			}
			p.mu.Unlock()
			close(p.done)
		}
	}()
	if r.historyRoot != "" {
		if err = os.MkdirAll(r.processDir(id, p.info.ID), 0700); err != nil {
			return ProcessInfo{}, err
		}
		if err = r.saveProcess(p); err != nil {
			return ProcessInfo{}, err
		}
	}
	ps := *spec.Process
	ps.Args = req.Command
	ps.Terminal = false
	ps.Env = mergeEnv(ps.Env, req.Env)
	if req.Cwd != "" {
		ps.Cwd = req.Cwd
	}
	// IO and Wait must outlive the initiating HTTP request, including disconnect.
	background, cancel := context.WithCancel(r.ctx(context.Background()))
	creator := cio.NewCreator(cio.WithStreams(nil, &p.out, &p.stderr))
	if r.historyRoot != "" {
		dir := r.processDir(id, p.info.ID)
		for _, name := range []string{"stdout", "stderr"} {
			if e := syscall.Mkfifo(filepath.Join(dir, name+".pipe"), 0600); e != nil {
				cancel()
				return ProcessInfo{}, e
			}
		}
		binary, e := os.Executable()
		if e != nil {
			cancel()
			return ProcessInfo{}, e
		}
		collector := exec.Command(binary, "-log-dir", dir)
		collector.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		collector.Stdout = os.Stdout
		collector.Stderr = os.Stderr
		if e = collector.Start(); e != nil {
			cancel()
			return ProcessInfo{}, e
		}
		go func() {
			if e := collector.Wait(); e != nil {
				slog.Error("logger.exit", "process_id", p.info.ID, "error", e)
			}
		}()
		creator = durableCreator(dir)
	}
	proc, err := t.Exec(background, p.info.ID, &ps, creator)
	if err != nil {
		cancel()
		return ProcessInfo{}, err
	}
	p.proc = proc
	err = proc.Start(ctx)
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
	p.mu.Lock()
	p.info.Status = "running"
	err = r.saveProcess(p)
	p.mu.Unlock()
	cancel()
	r.watchProcess(p)
	return p.snapshot(), err
}

func (r *Runtime) watchProcess(p *trackedProcess) {
	go func() {
		defer close(p.done)
		ctx := r.ctx(context.Background())
		for {
			state, err := p.proc.Status(ctx)
			if errdefs.IsNotFound(err) {
				p.mu.Lock()
				p.info.Status = "error"
				p.info.Error = "Runtime process missing; exit code unavailable"
				at := time.Now().UTC()
				p.info.CompletedAt = &at
				err = r.saveProcess(p)
				p.mu.Unlock()
				if err == nil {
					return
				}
				slog.Error("process.persist.failed", "error", err)
				time.Sleep(time.Second)
				continue
			}
			if err != nil {
				slog.Error("process.status.failed", "process_id", p.info.ID, "error", err)
				time.Sleep(time.Second)
				continue
			}
			if state.Status != containerd.Stopped {
				info := p.snapshot()
				if info.Timeout > 0 && time.Since(info.StartedAt) >= time.Duration(info.Timeout)*time.Second {
					p.mu.Lock()
					p.info.TimedOut = true
					p.mu.Unlock()
					if e := p.proc.Kill(ctx, syscall.SIGKILL); e != nil && !errdefs.IsNotFound(e) {
						slog.Error("process.timeout.failed", "error", e)
					}
				}
				time.Sleep(100 * time.Millisecond)
				continue
			}
			code, at := state.ExitStatus, state.ExitTime
			// The shim logger finishes independently. Wait for its durable final marker.
			if r.historyRoot != "" {
				for i := 0; i < 100; i++ {
					if _, e := os.Stat(filepath.Join(r.processDir(p.info.SandboxID, p.info.ID), "logs.done")); e == nil {
						break
					}
					time.Sleep(10 * time.Millisecond)
				}
			}
			completeLogs := true
			if r.historyRoot != "" {
				_, e := os.Stat(filepath.Join(r.processDir(p.info.SandboxID, p.info.ID), "logs.done"))
				completeLogs = e == nil
			}
			p.mu.Lock()
			if !completeLogs {
				p.info.Error = "Log capture did not finish successfully"
			}
			p.info.Status = "exited"
			p.info.ExitCode = &code
			if at.IsZero() {
				at = time.Now().UTC()
			}
			p.info.CompletedAt = &at
			err = r.saveProcess(p)
			p.mu.Unlock()
			if err != nil {
				slog.Error("process.persist.failed", "process_id", p.info.ID, "error", err)
				time.Sleep(time.Second)
				continue
			}
			// Never delete the sole runtime exit record before metadata has been fsynced.
			clean, cancel := context.WithTimeout(ctx, 10*time.Second)
			_, err = p.proc.Delete(clean)
			cancel()
			if err != nil && !errdefs.IsNotFound(err) {
				slog.Error("process.cleanup.failed", "process_id", p.info.ID, "error", err)
			}
			slog.Info("process.exit", "process_id", p.info.ID, "exit_code", code)
			return
		}
	}()
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
	if r.historyRoot != "" {
		dir := r.processDir(id, pid)
		out, e := os.ReadFile(filepath.Join(dir, "stdout"))
		if e != nil && !os.IsNotExist(e) {
			return nil, e
		}
		stderr, e := os.ReadFile(filepath.Join(dir, "stderr"))
		if e != nil && !os.IsNotExist(e) {
			return nil, e
		}
		_, a := os.Stat(filepath.Join(dir, "stdout.truncated"))
		_, b := os.Stat(filepath.Join(dir, "stderr.truncated"))
		return map[string]any{"stdout": string(out), "stderr": string(stderr), "truncated": a == nil || b == nil}, nil
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
func (r *Runtime) forgetProcesses(id string) error {
	if r.historyRoot != "" {
		if err := os.RemoveAll(filepath.Join(r.historyRoot, id)); err != nil {
			return err
		}
	}
	r.processMu.Lock()
	defer r.processMu.Unlock()
	for pid, p := range r.processes {
		if p.info.SandboxID == id {
			delete(r.processes, pid)
		}
	}
	return nil
}
