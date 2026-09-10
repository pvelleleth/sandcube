package main

import (
	"context"
	"encoding/json"
	"github.com/containerd/errdefs"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

type fakeBackend struct {
	called  int
	err     error
	config  Config
	execReq ExecRequest
}

func (f *fakeBackend) Health(context.Context) error { return f.err }
func (f *fakeBackend) Create(_ context.Context, c Config) (Sandbox, error) {
	f.called++
	f.config = c
	return Sandbox{ID: c.ID, Status: "stopped"}, f.err
}
func (f *fakeBackend) Start(context.Context, string) (Sandbox, error) {
	f.called++
	return Sandbox{Status: "running"}, f.err
}
func (f *fakeBackend) Stop(context.Context, string) (Sandbox, error) {
	f.called++
	return Sandbox{Status: "stopped"}, f.err
}
func (f *fakeBackend) Inspect(context.Context, string) (Sandbox, error) {
	f.called++
	return Sandbox{}, f.err
}
func (f *fakeBackend) Delete(context.Context, string) error { f.called++; return f.err }
func (f *fakeBackend) Exec(_ context.Context, _ string, r ExecRequest) (ExecResult, error) {
	f.called++
	f.execReq = r
	return ExecResult{ExitCode: 7, Stderr: "failure"}, f.err
}
func TestInvalidRequestsNeverReachRuntime(t *testing.T) {
	for _, body := range []string{`{}`, `{"id":"../../host"}`, `{"id":"sbx_test","image":"busybox","command":["sleep"],"cpu":1,"memory_mb":256,"pids":128,"runtime":"runc"}`, strings.Repeat("x", 65537), `null`, `{} {}`} {
		f := &fakeBackend{}
		s := &server{backend: f}
		w := httptest.NewRecorder()
		s.ServeHTTP(w, httptest.NewRequest("POST", "/containers", strings.NewReader(body)))
		if w.Code != 400 || f.called != 0 {
			t.Fatalf("body %.80s: status %d calls %d", body, w.Code, f.called)
		}
	}
}
func TestCreateContract(t *testing.T) {
	f := &fakeBackend{}
	s := &server{backend: f}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, httptest.NewRequest("POST", "/containers", strings.NewReader(`{"id":"sbx_test","image":"busybox","command":["sleep","infinity"],"cpu":1,"memory_mb":256,"pids":128}`)))
	if w.Code != 201 || f.config.Image != "busybox" {
		t.Fatal(w.Code, w.Body.String())
	}
}
func TestErrorMapping(t *testing.T) {
	for _, tc := range []struct {
		err    error
		status int
	}{{errdefs.ErrNotFound, 404}, {errdefs.ErrAlreadyExists, 409}, {errdefs.ErrFailedPrecondition, 409}} {
		s := &server{backend: &fakeBackend{err: tc.err}}
		w := httptest.NewRecorder()
		s.ServeHTTP(w, httptest.NewRequest("GET", "/containers/sbx_test", nil))
		if w.Code != tc.status {
			t.Fatal(w.Code)
		}
		var result map[string]any
		if json.Unmarshal(w.Body.Bytes(), &result) != nil || result["error"] == nil {
			t.Fatal(w.Body.String())
		}
	}
}
func TestExecExitCodeAndDefaultTimeout(t *testing.T) {
	f := &fakeBackend{}
	s := &server{backend: f}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, httptest.NewRequest("POST", "/containers/sbx_test/exec", strings.NewReader(`{"command":["false"]}`)))
	if w.Code != 200 || f.execReq.Timeout != 30 || !strings.Contains(w.Body.String(), `"exit_code":7`) {
		t.Fatal(w.Code, w.Body.String())
	}
}
func TestOutputBoundIsConcurrentAndDrains(t *testing.T) {
	var b limitedBuffer
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			p := []byte(strings.Repeat("a", 700000))
			n, e := b.Write(p)
			if n != len(p) || e != nil {
				t.Error(n, e)
			}
		}()
	}
	wg.Wait()
	s, truncated := b.result()
	if len(s) != 1024*1024 || !truncated {
		t.Fatal(len(s), truncated)
	}
}

func TestEnvironmentOverridesReplaceImageValues(t *testing.T) {
	got := mergeEnv([]string{"PATH=/image/bin", "LANG=C", "PATH=/last/bin"}, map[string]string{"PATH": "/custom/bin", "TOKEN": "a=b"})
	want := []string{"LANG=C", "PATH=/custom/bin", "TOKEN=a=b"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}

type blockingBackend struct {
	fakeBackend
	active  atomic.Int32
	maximum atomic.Int32
	entered chan struct{}
	release chan struct{}
}

func (b *blockingBackend) Start(ctx context.Context, id string) (Sandbox, error) {
	n := b.active.Add(1)
	for old := b.maximum.Load(); n > old; old = b.maximum.Load() {
		if b.maximum.CompareAndSwap(old, n) {
			break
		}
	}
	b.entered <- struct{}{}
	select {
	case <-b.release:
	case <-ctx.Done():
	}
	b.active.Add(-1)
	return Sandbox{ID: id, Status: "running"}, nil
}
func TestLifecycleSerializesConcurrentStarts(t *testing.T) {
	b := &blockingBackend{entered: make(chan struct{}, 8), release: make(chan struct{})}
	s := &server{backend: b}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := httptest.NewRecorder()
			s.ServeHTTP(w, httptest.NewRequest("POST", "/containers/sbx_same/start", nil))
			if w.Code != 200 {
				t.Error(w.Code)
			}
		}()
	}
	<-b.entered
	close(b.release)
	wg.Wait()
	if b.maximum.Load() != 1 {
		t.Fatalf("overlapping lifecycle calls: %d", b.maximum.Load())
	}
}
