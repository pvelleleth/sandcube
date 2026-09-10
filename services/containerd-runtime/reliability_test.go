package main

import (
	"context"
	"encoding/json"
	"errors"
	containerd "github.com/containerd/containerd/v2/client"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestDurableLogCaptureBoundsAndStreams(t *testing.T) {
	dir := t.TempDir()
	var wg sync.WaitGroup
	for _, name := range []string{"stdout", "stderr"} {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			f, e := os.Create(filepath.Join(dir, name))
			if e != nil {
				t.Error(e)
				return
			}
			defer f.Close()
			if e = captureLog(strings.NewReader(strings.Repeat(name, logLimit)), f, filepath.Join(dir, name+".truncated")); e != nil {
				t.Error(e)
			}
		}(name)
	}
	wg.Wait()
	for _, name := range []string{"stdout", "stderr"} {
		b, e := os.ReadFile(filepath.Join(dir, name))
		if e != nil || len(b) != logLimit || !strings.HasPrefix(string(b), name) {
			t.Fatalf("capture %s: %d %v", name, len(b), e)
		}
		if _, e = os.Stat(filepath.Join(dir, name+".truncated")); e != nil {
			t.Fatal(e)
		}
	}
}
func TestProcessHistorySurvivesNewAdapter(t *testing.T) {
	root := t.TempDir()
	r := &Runtime{historyRoot: root}
	id := "sbx_test"
	pid := "proc_" + strings.Repeat("a", 32)
	if e := os.MkdirAll(r.processDir(id, pid), 0700); e != nil {
		t.Fatal(e)
	}
	code := uint32(23)
	at := time.Now().UTC()
	p := &trackedProcess{info: ProcessInfo{ID: pid, SandboxID: id, Command: []string{"sh", "-c", "exit 23"}, Status: "exited", ExitCode: &code, CompletedAt: &at}}
	if e := r.saveProcess(p); e != nil {
		t.Fatal(e)
	}
	restarted := &Runtime{historyRoot: root}
	if e := restarted.recoverProcesses(context.Background()); e != nil {
		t.Fatal(e)
	}
	restored, e := restarted.lookupProcess(id, pid)
	if e != nil {
		t.Fatal(e)
	}
	info := restored.snapshot()
	if *info.ExitCode != 23 || info.Status != "exited" || !info.CompletedAt.Equal(at) {
		t.Fatal(info)
	}
	select {
	case <-restored.done:
	default:
		t.Fatal("terminal history not settled")
	}
	restarted.forgetProcesses(id)
	if _, e = os.Stat(filepath.Join(root, id)); !os.IsNotExist(e) {
		t.Fatal("history leaked", e)
	}
}
func TestAtomicMetadataRejectsCorruptHistory(t *testing.T) {
	root := t.TempDir()
	r := &Runtime{historyRoot: root}
	dir := r.processDir("sbx_test", "proc_"+strings.Repeat("b", 32))
	if e := os.MkdirAll(dir, 0700); e != nil {
		t.Fatal(e)
	}
	path := filepath.Join(dir, "process.json")
	for i := 0; i < 10; i++ {
		if e := atomicJSON(path, map[string]int{"version": i}); e != nil {
			t.Fatal(e)
		}
		b, e := os.ReadFile(path)
		if e != nil || !json.Valid(b) {
			t.Fatal("invalid commit", e)
		}
	}
	if e := os.WriteFile(path, []byte("{"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := r.recoverProcesses(context.Background()); e == nil {
		t.Fatal("corrupt history silently discarded")
	}
}

type failingProcessCleanup struct {
	containerd.Process
	attempts int
}

func (*failingProcessCleanup) Status(context.Context) (containerd.Status, error) {
	return containerd.Status{Status: containerd.Stopped}, nil
}
func (p *failingProcessCleanup) Delete(context.Context, ...containerd.ProcessDeleteOpts) (*containerd.ExitStatus, error) {
	p.attempts++
	if p.attempts == 1 {
		return nil, errors.New("injected runtime deletion failure")
	}
	return containerd.NewExitStatus(0, time.Now(), nil), nil
}
func TestTerminalRuntimeCleanupRetriesWithoutDroppingHistory(t *testing.T) {
	proc := &failingProcessCleanup{}
	p := &trackedProcess{info: ProcessInfo{ID: "proc_test", SandboxID: "sbx_test", Status: "exited"}, proc: proc, done: make(chan struct{})}
	close(p.done)
	r := &Runtime{processes: map[string]*trackedProcess{"proc_test": p}}
	if err := r.cleanupProcessRecords(context.Background()); err == nil {
		t.Fatal("cleanup error hidden")
	}
	if err := r.cleanupProcessRecords(context.Background()); err != nil {
		t.Fatal(err)
	}
	if proc.attempts != 2 || len(r.processes) != 1 || p.snapshot().Status != "exited" {
		t.Fatal("cleanup lost durable history")
	}
}
func TestRecoveryCleansUncommittedProcessDirectories(t *testing.T) {
	root := t.TempDir()
	r := &Runtime{historyRoot: root}
	dir := r.processDir("sbx_test", "proc_"+strings.Repeat("c", 32))
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".pending-metadata"), []byte("partial"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := r.recoverProcesses(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatal("uncommitted history directory leaked", err)
	}
}
