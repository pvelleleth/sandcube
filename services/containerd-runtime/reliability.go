package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/containerd/containerd/v2/core/snapshots"
	"github.com/containerd/errdefs"
)

func atomicJSON(path string, value any) error {
	b, err := json.Marshal(value)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".pending-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(f.Name(), path); err != nil {
		return err
	}
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
func (r *Runtime) List(ctx context.Context) ([]Sandbox, error) {
	ctx = r.ctx(ctx)
	cs, err := r.client.Containers(ctx, "labels.\""+ownerLabel+"\"==true")
	if err != nil {
		return nil, err
	}
	result := []Sandbox{}
	for _, c := range cs {
		if !validID.MatchString(c.ID()) {
			continue
		}
		if _, e := r.load(ctx, c.ID()); e != nil {
			if errdefs.IsNotFound(e) {
				continue
			}
			return nil, e
		}
		s, e := r.describe(ctx, c)
		if e != nil {
			return nil, e
		}
		result = append(result, s)
	}
	return result, nil
}
func (r *Runtime) Reconcile(ctx context.Context) (any, error) {
	if err := r.cleanupProcessRecords(ctx); err != nil {
		return nil, err
	}
	// Shares imageMu with create; labels establish ownership even before container
	// metadata commits. Never infer ownership from a snapshot name alone.
	r.imageMu.Lock()
	defer r.imageMu.Unlock()
	ctx = r.ctx(ctx)
	cs, err := r.client.Containers(ctx)
	if err != nil {
		return nil, err
	}
	used := map[string]bool{}
	for _, c := range cs {
		info, e := c.Info(ctx)
		if e != nil {
			return nil, e
		}
		used[info.SnapshotKey] = true
	}
	keys := []string{}
	err = r.client.SnapshotService("overlayfs").Walk(ctx, func(ctx context.Context, info snapshots.Info) error {
		if info.Labels[ownerLabel] == "true" && !used[info.Name] {
			keys = append(keys, info.Name)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	for _, key := range keys {
		if err = r.client.SnapshotService("overlayfs").Remove(ctx, key); err != nil && !errdefs.IsNotFound(err) {
			return nil, err
		}
		slog.Info("snapshot.orphan.cleaned", "snapshot", key)
	}
	// Process directories with no container are sandbox-specific garbage.
	entries, err := os.ReadDir(r.historyRoot)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if !entry.IsDir() || !validID.MatchString(entry.Name()) {
			continue
		}
		if _, e := r.load(ctx, entry.Name()); errdefs.IsNotFound(e) {
			if e = r.settleProcesses(ctx, entry.Name()); e != nil {
				return nil, e
			}
			if e = r.forgetProcesses(entry.Name()); e != nil {
				return nil, e
			}
		} else if e != nil {
			return nil, e
		}
	}
	return map[string]any{"snapshots_cleaned": len(keys)}, nil
}
func (r *Runtime) processDir(id, pid string) string { return filepath.Join(r.historyRoot, id, pid) }
func (r *Runtime) saveProcess(p *trackedProcess) error {
	if r.historyRoot == "" {
		return nil
	}
	return atomicJSON(filepath.Join(r.processDir(p.info.SandboxID, p.info.ID), "process.json"), p.info)
}
func (r *Runtime) recoverProcesses(ctx context.Context) error {
	if err := os.MkdirAll(r.historyRoot, 0700); err != nil {
		return err
	}
	// A crash before the first metadata rename cannot have launched an exec.
	// Only do this before serving requests, never concurrently with process setup.
	dirs, err := filepath.Glob(filepath.Join(r.historyRoot, "sbx_*", "proc_*"))
	if err != nil {
		return err
	}
	for _, dir := range dirs {
		if !validID.MatchString(filepath.Base(filepath.Dir(dir))) || !validProcessID.MatchString(filepath.Base(dir)) {
			continue
		}
		if _, e := os.Stat(filepath.Join(dir, "process.json")); os.IsNotExist(e) {
			if e = os.RemoveAll(dir); e != nil {
				return e
			}
		} else if e != nil {
			return e
		}
	}
	paths, err := filepath.Glob(filepath.Join(r.historyRoot, "sbx_*", "proc_*", "process.json"))
	if err != nil {
		return err
	}
	r.processes = map[string]*trackedProcess{}
	for _, path := range paths {
		b, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		var info ProcessInfo
		if e = json.Unmarshal(b, &info); e != nil {
			return fmt.Errorf("corrupt process metadata %s: %w", path, e)
		}
		if !validID.MatchString(info.SandboxID) || !validProcessID.MatchString(info.ID) || filepath.Clean(path) != filepath.Join(r.processDir(info.SandboxID, info.ID), "process.json") {
			return fmt.Errorf("invalid process metadata %s", path)
		}
		p := &trackedProcess{info: info, done: make(chan struct{})}
		r.processes[info.ID] = p
		terminal := info.Status == "exited" || info.Status == "error"
		if r.client == nil && terminal {
			close(p.done)
			continue
		}

		c, e := r.load(r.ctx(ctx), info.SandboxID)
		if e == nil {
			t, te := c.Task(r.ctx(ctx), nil)
			e = te
			if e == nil {
				p.proc, e = t.LoadProcess(r.ctx(ctx), info.ID, nil)
			}
		}
		if errdefs.IsNotFound(e) {
			if terminal {
				close(p.done)
				continue
			}
			p.info.Status = "error"
			p.info.Error = "Process missing after runtime restart; exit code unavailable"
			at := time.Now().UTC()
			p.info.CompletedAt = &at
			if e = r.saveProcess(p); e != nil {
				return e
			}
			close(p.done)
			continue
		}
		if e != nil {
			return e
		}
		state, e := p.proc.Status(r.ctx(ctx))
		if e != nil {
			return e
		}
		if state.Status == "created" { // intent was durable, but Start never completed; do not execute it twice.
			p.info.Status = "error"
			p.info.Error = "Process start interrupted"
			at := time.Now().UTC()
			p.info.CompletedAt = &at
			if e = r.saveProcess(p); e != nil {
				return e
			}
			_, _ = p.proc.Delete(r.ctx(ctx))
			close(p.done)
			continue
		}
		if state.Status == "stopped" && terminal {
			if _, e = p.proc.Delete(r.ctx(ctx)); e != nil && !errdefs.IsNotFound(e) {
				return e
			}
			close(p.done)
			continue
		}
		if state.Status == "running" {
			p.info.Status = "running"
			p.info.Error = ""
			if e = r.saveProcess(p); e != nil {
				return e
			}
		}
		r.watchProcess(p)
	}
	return nil
}

// Retry runtime record deletion after an exit was durably saved. Keeping history
// and retiring the runtime exec are separate operations with separate lifetimes.
func (r *Runtime) cleanupProcessRecords(ctx context.Context) error {
	r.processMu.Lock()
	ps := make([]*trackedProcess, 0, len(r.processes))
	for _, p := range r.processes {
		ps = append(ps, p)
	}
	r.processMu.Unlock()
	for _, p := range ps {
		select {
		case <-p.done:
		default:
			continue
		}
		if p.proc == nil {
			continue
		}
		state, err := p.proc.Status(r.ctx(ctx))
		if errdefs.IsNotFound(err) {
			continue
		}
		if err != nil {
			return err
		}
		if state.Status != "stopped" && state.Status != "created" {
			continue
		}
		if _, err = p.proc.Delete(r.ctx(ctx)); err != nil && !errdefs.IsNotFound(err) {
			return err
		}
	}
	return nil
}
