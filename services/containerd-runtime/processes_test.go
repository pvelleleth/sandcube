package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
)

type processBackend struct {
	fakeBackend
	processCalls int
	req          ExecRequest
}

func (b *processBackend) StartProcess(_ context.Context, id string, req ExecRequest) (ProcessInfo, error) {
	b.processCalls++
	b.req = req
	return ProcessInfo{ID: "proc_test", SandboxID: id, Status: "running"}, nil
}
func (b *processBackend) Processes(context.Context, string) ([]ProcessInfo, error) {
	b.processCalls++
	return []ProcessInfo{}, nil
}
func (b *processBackend) Process(context.Context, string, string) (ProcessInfo, error) {
	b.processCalls++
	return ProcessInfo{Status: "exited"}, nil
}
func (b *processBackend) ProcessLogs(context.Context, string, string) (any, error) {
	b.processCalls++
	return map[string]string{"stdout": "log"}, nil
}
func (b *processBackend) KillProcess(context.Context, string, string) (ProcessInfo, error) {
	b.processCalls++
	return ProcessInfo{Status: "exited"}, nil
}
func TestProcessRoutesAndValidation(t *testing.T) {
	for _, body := range []string{`{}`, `null`, `{"command":[]}`, `{"command":[""]}`, `{"command":["sleep"],"timeout_seconds":1}`, `{"command":["sleep"],"cwd":"relative"}`, `{"command":["sleep"],"privileged":true}`} {
		b := &processBackend{}
		s := &server{backend: b}
		w := httptest.NewRecorder()
		s.ServeHTTP(w, httptest.NewRequest("POST", "/containers/sbx_test/processes", strings.NewReader(body)))
		if w.Code != 400 || b.processCalls != 0 {
			t.Fatalf("%s: %d %s", body, w.Code, w.Body.String())
		}
	}
	b := &processBackend{}
	s := &server{backend: b}
	for _, tc := range []struct {
		method, path, body string
		status             int
	}{
		{"POST", "/processes", `{"command":["sleep","600"],"env":{"A":"b"},"cwd":"/app"}`, 202},
		{"GET", "/processes", "", 200}, {"GET", "/processes/proc_test", "", 200}, {"GET", "/processes/proc_test/logs", "", 200}, {"POST", "/processes/proc_test/kill", "", 200},
	} {
		w := httptest.NewRecorder()
		s.ServeHTTP(w, httptest.NewRequest(tc.method, "/containers/sbx_test"+tc.path, strings.NewReader(tc.body)))
		if w.Code != tc.status {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	if b.processCalls != 5 || b.req.Env["A"] != "b" || b.req.Cwd != "/app" {
		t.Fatal("process contract", b)
	}
}

func TestProcessScopeAndHistoryCleanup(t *testing.T) {
	r := &Runtime{processes: map[string]*trackedProcess{
		"proc_a": {info: ProcessInfo{ID: "proc_a", SandboxID: "sbx_a"}},
		"proc_b": {info: ProcessInfo{ID: "proc_b", SandboxID: "sbx_b"}},
	}}
	if _, err := r.lookupProcess("sbx_b", "proc_a"); err == nil {
		t.Fatal("cross sandbox process access")
	}
	r.forgetProcesses("sbx_a")
	if _, err := r.lookupProcess("sbx_a", "proc_a"); err == nil {
		t.Fatal("deleted history retained")
	}
	if _, err := r.lookupProcess("sbx_b", "proc_b"); err != nil {
		t.Fatal("other history removed")
	}
}
