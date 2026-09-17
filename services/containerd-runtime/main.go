package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/errdefs"
	"golang.org/x/sys/unix"
	"io"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

var validID = regexp.MustCompile(`^sbx_[a-zA-Z0-9_-]{1,80}$`)

type server struct {
	backend   Backend
	locks     [256]sync.Mutex
	lifecycle sync.Mutex
}

func (s *server) lock(id string) func() {
	s.lifecycle.Lock()
	var h byte
	for i := range id {
		h = h*31 + id[i]
	}
	s.locks[h].Lock()
	return func() { s.locks[h].Unlock(); s.lifecycle.Unlock() }
}
func respond(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func failure(w http.ResponseWriter, status int, code string, err error) {
	runtimeFailures.Add(1)
	slog.Error("runtime.error", "code", code, "status", status, "error", err)
	respond(w, status, map[string]any{"error": map[string]string{"code": code, "message": err.Error()}})
}
func decode(w http.ResponseWriter, r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if e := d.Decode(v); e != nil {
		return e
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("expected one JSON object")
	}
	return nil
}
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	runtimeRequests.Add(1)
	defer func() { runtimeDurationMillis.Add(uint64(time.Since(started).Milliseconds())) }()
	defer func() {
		slog.Info("runtime.request", "method", r.Method, "path", r.URL.Path, "duration_ms", time.Since(started).Milliseconds())
	}()
	timeout := 45 * time.Second
	if strings.HasSuffix(r.URL.Path, "/exec") {
		timeout = time.Hour + 30*time.Second
	}
	if r.URL.Path == "/images/import" || (r.Method == "POST" && r.URL.Path == "/containers") {
		timeout = 10 * time.Minute
	}
	if r.URL.Path == "/health" {
		timeout = 5 * time.Second
	}
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()
	if r.Method == "GET" && r.URL.Path == "/health" {
		if e := s.backend.Health(ctx); e != nil {
			failure(w, 503, "RUNTIME_UNAVAILABLE", e)
		} else {
			respond(w, 200, map[string]string{"status": "ok"})
		}
		return
	}
	var value any
	var err error
	status := 200
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if r.Method == "GET" && r.URL.Path == "/metrics" {
		b, ok := s.backend.(interface {
			Metrics(context.Context) (any, error)
		})
		if !ok {
			failure(w, 503, "UNAVAILABLE", errors.New("metrics unavailable"))
			return
		}
		value, err = b.Metrics(ctx)
	} else if r.Method == "GET" && r.URL.Path == "/containers" {
		b, ok := s.backend.(interface {
			List(context.Context) ([]Sandbox, error)
		})
		if !ok {
			failure(w, 503, "UNAVAILABLE", errors.New("inventory unavailable"))
			return
		}
		value, err = b.List(ctx)
	} else if r.Method == "POST" && r.URL.Path == "/reconcile" {
		b, ok := s.backend.(interface {
			Reconcile(context.Context) (any, error)
		})
		if !ok {
			failure(w, 503, "UNAVAILABLE", errors.New("reconciliation unavailable"))
			return
		}
		s.lifecycle.Lock()
		value, err = b.Reconcile(ctx)
		s.lifecycle.Unlock()
	} else if r.Method == "POST" && len(parts) == 2 && parts[0] == "images" {
		backend, ok := s.backend.(ImageBackend)
		if !ok {
			failure(w, 503, "IMAGES_UNAVAILABLE", errors.New("image backend unavailable"))
			return
		}
		var req ImageRequest
		if err = decode(w, r, &req); err != nil || !managedReference.MatchString(req.Reference) {
			failure(w, 400, "INVALID_REQUEST", errors.New("invalid image request"))
			return
		}
		switch parts[1] {
		case "import":
			value, err = backend.ImportImage(ctx, req)
		case "inspect":
			value, err = backend.InspectImage(ctx, req.Reference)
		case "delete":
			err = backend.DeleteImage(ctx, req.Reference)
			value = map[string]string{"status": "deleted"}
		default:
			failure(w, 404, "NOT_FOUND", errors.New("unknown route"))
			return
		}
	} else if r.Method == "POST" && r.URL.Path == "/containers" {
		c := Config{DiskMB: 1024}
		if err = decode(w, r, &c); err != nil {
			failure(w, 400, "INVALID_REQUEST", err)
			return
		}
		if c.DiskMB < 16 || c.DiskMB > 1048576 || !validID.MatchString(c.ID) || c.Image == "" || len(c.Command) == 0 || c.Command[0] == "" || c.CPU < 1 || c.CPU > 64 || c.MemoryMB < 16 || c.MemoryMB > 262144 || c.Pids < 1 || c.Pids > 65536 {
			failure(w, 400, "INVALID_REQUEST", errors.New("invalid ID, image, command or resource limits"))
			return
		}
		unlock := s.lock(c.ID)
		defer func() { unlock() }()
		value, err = s.backend.Create(ctx, c)
		status = 201
	} else if len(parts) >= 2 && parts[0] == "containers" && validID.MatchString(parts[1]) {
		id := parts[1]
		unlock := s.lock(id)
		defer func() { unlock() }()
		switch {
		case len(parts) == 3 && parts[2] == "files" && r.Method == "POST":
			backend, ok := s.backend.(FileBackend)
			if !ok {
				failure(w, 503, "FILES_UNAVAILABLE", errors.New("file backend unavailable"))
				return
			}
			var req FileRequest
			r.Body = http.MaxBytesReader(w, r.Body, 24<<20)
			d := json.NewDecoder(r.Body)
			d.DisallowUnknownFields()
			if e := d.Decode(&req); e != nil {
				failure(w, 400, "INVALID_REQUEST", e)
				return
			}
			if d.Decode(new(any)) != io.EOF {
				failure(w, 400, "INVALID_REQUEST", errors.New("expected one object"))
				return
			}
			value, err = backend.File(ctx, id, req)
		case len(parts) >= 3 && parts[2] == "processes":
			backend, ok := s.backend.(ProcessBackend)
			if !ok {
				failure(w, 503, "PROCESSES_UNAVAILABLE", errors.New("process backend unavailable"))
				return
			}
			switch {
			case len(parts) == 3 && r.Method == "POST":
				var req ExecRequest
				if e := decode(w, r, &req); e != nil {
					failure(w, 400, "INVALID_REQUEST", e)
					return
				}
				if len(req.Command) == 0 || req.Command[0] == "" || req.Timeout != 0 || (req.Cwd != "" && !strings.HasPrefix(req.Cwd, "/")) {
					failure(w, 400, "INVALID_REQUEST", errors.New("invalid command/cwd; detached execution does not accept a timeout"))
					return
				}
				value, err = backend.StartProcess(ctx, id, req)
				status = 202
			case len(parts) == 3 && r.Method == "GET":
				value, err = backend.Processes(ctx, id)
			case len(parts) == 4 && r.Method == "GET":
				value, err = backend.Process(ctx, id, parts[3])
			case len(parts) == 5 && parts[4] == "logs" && r.Method == "GET":
				value, err = backend.ProcessLogs(ctx, id, parts[3])
			case len(parts) == 5 && parts[4] == "kill" && r.Method == "POST":
				value, err = backend.KillProcess(ctx, id, parts[3])
			default:
				failure(w, 404, "NOT_FOUND", errors.New("unknown route"))
				return
			}
		case len(parts) == 2 && r.Method == "GET":
			value, err = s.backend.Inspect(ctx, id)
		case len(parts) == 2 && r.Method == "DELETE":
			err = s.backend.Delete(ctx, id)
			value = map[string]string{"id": id, "status": "deleted"}
		case len(parts) == 3 && r.Method == "POST" && parts[2] == "start":
			value, err = s.backend.Start(ctx, id)
		case len(parts) == 3 && r.Method == "POST" && parts[2] == "stop":
			value, err = s.backend.Stop(ctx, id)
		case len(parts) == 3 && r.Method == "POST" && parts[2] == "exec":
			var req ExecRequest
			if err = decode(w, r, &req); err != nil {
				failure(w, 400, "INVALID_REQUEST", err)
				return
			}
			if req.Timeout == 0 {
				req.Timeout = 30
			}
			if len(req.Command) == 0 || req.Command[0] == "" || req.Timeout < 1 || req.Timeout > 3600 || (req.Cwd != "" && !strings.HasPrefix(req.Cwd, "/")) {
				failure(w, 400, "INVALID_REQUEST", errors.New("invalid command, cwd or timeout"))
				return
			}
			if backend, ok := s.backend.(interface {
				PrepareExec(context.Context, string, ExecRequest) (func() (ExecResult, error), error)
			}); ok {
				var wait func() (ExecResult, error)
				wait, err = backend.PrepareExec(ctx, id, req)
				unlock()
				unlock = func() {}
				if err == nil {
					value, err = wait()
				}
				break
			}
			// Exec must not hold the lifecycle lock while waiting: stop/delete can cancel tasks.
			unlock()
			unlock = func() {}
			value, err = s.backend.Exec(ctx, id, req)
		default:
			failure(w, 404, "NOT_FOUND", errors.New("unknown route"))
			return
		}
	} else {
		failure(w, 404, "NOT_FOUND", errors.New("unknown route"))
		return
	}
	if err != nil {
		code := "RUNTIME_ERROR"
		status = 500
		switch {
		case errors.Is(err, errInvalidPath):
			status = 400
			code = "INVALID_PATH"
		case errors.Is(err, unix.EDQUOT), errors.Is(err, unix.ENOSPC), errors.Is(err, errFileTooLarge), errdefs.IsResourceExhausted(err):
			status = 413
			code = "LIMIT_EXCEEDED"
		case errors.Is(err, unix.ENOENT):
			status = 404
			code = "FILE_NOT_FOUND"
		case errors.Is(err, unix.EEXIST), errors.Is(err, unix.ENOTEMPTY), errors.Is(err, unix.EISDIR), errors.Is(err, unix.ENOTDIR):
			status = 409
			code = "FILE_CONFLICT"
		case errdefs.IsNotFound(err):
			status = 404
			code = "NOT_FOUND"
		case errdefs.IsAlreadyExists(err):
			status = 409
			code = "ALREADY_EXISTS"
		case errdefs.IsFailedPrecondition(err):
			status = 409
			code = "SANDBOX_NOT_RUNNING"
			if parts[0] == "images" {
				code = "IMAGE_IN_USE"
			}
		}
		failure(w, status, code, err)
		return
	}
	respond(w, status, value)
}
func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	logDir := flag.String("log-dir", "", "internal shim log collector mode")
	historyRoot := flag.String("history-root", "/var/lib/sandcube/processes", "durable process history directory, scoped by namespace")
	socket := flag.String("socket", "/run/sandcube/runtime.sock", "private Unix socket")
	address := flag.String("containerd", "/run/sandcube-containerd/containerd.sock", "containerd socket")
	stateRoot := flag.String("containerd-state", "", "containerd state directory (default: socket directory)")
	configPath := flag.String("runsc-config", "/etc/sandcube/runsc.toml", "gVisor configuration (overlay2=none required)")
	buildRoot := flag.String("build-root", "/var/lib/sandcube/builds", "shared private build directory")
	namespace := flag.String("namespace", "sandcube", "dedicated containerd namespace")
	flag.Parse()
	if *logDir != "" {
		if err := runLogger(*logDir); err != nil {
			slog.Error("logger.failed", "error", err)
			os.Exit(1)
		}
		return
	}
	// Hold the socket lock for the adapter lifetime, including recovery. A SIGKILL
	// leaves a socket inode but releases flock, so restarting needs no manual unlink.
	lock, err := os.OpenFile(*socket+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		log.Fatal(err)
	}
	defer lock.Close()
	if err = unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		log.Fatal("adapter already running: ", err)
	}
	if *stateRoot == "" {
		*stateRoot = filepath.Dir(*address)
	}
	if _, err := os.Stat(*configPath); err != nil {
		log.Fatal(err)
	}
	if !regexp.MustCompile(`^[a-zA-Z0-9_-]{1,80}$`).MatchString(*namespace) {
		log.Fatal("invalid namespace")
	}
	namespaceLock, e := os.OpenFile(filepath.Join(*stateRoot, "sandcube-"+*namespace+".lock"), os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		log.Fatal(e)
	}
	defer namespaceLock.Close()
	if e = unix.Flock(int(namespaceLock.Fd()), unix.LOCK_EX|unix.LOCK_NB); e != nil {
		log.Fatal("namespace already has an adapter")
	}
	client, err := containerd.New(*address)
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()
	if info, e := os.Lstat(*socket); e == nil {
		if info.Mode()&os.ModeSocket == 0 {
			log.Fatal("socket path is not a socket")
		}
		conn, e := net.DialTimeout("unix", *socket, time.Second)
		if e == nil {
			conn.Close()
			log.Fatal("socket is live")
		}
		if err = os.Remove(*socket); err != nil {
			log.Fatal(err)
		}
	} else if !os.IsNotExist(e) {
		log.Fatal(e)
	}
	runtime := &Runtime{client: client, namespace: *namespace, configPath: *configPath, buildRoot: *buildRoot, stateRoot: *stateRoot, historyRoot: filepath.Join(*historyRoot, *namespace)}
	var hierarchy unix.Statfs_t
	if e := unix.Statfs("/sys/fs/cgroup", &hierarchy); e != nil || hierarchy.Type != unix.CGROUP2_SUPER_MAGIC {
		log.Fatal("cgroup v2 is required for memory, swap and group OOM enforcement")
	}
	// Host forwarding is provisioned by the operator; never silently alter host policy.
	forwarding, e := os.ReadFile("/proc/sys/net/ipv4/ip_forward")
	if e != nil || strings.TrimSpace(string(forwarding)) != "1" {
		log.Fatal("IPv4 forwarding must be enabled")
	}
	for _, tool := range []string{"ip", "nft", "sysctl", "conntrack"} {
		if _, e := exec.LookPath(tool); e != nil {
			log.Fatal(e)
		}
	}
	// Fail closed if inventory/history cannot be read; do not report invented exits.
	if err = runtime.recoverProcesses(context.Background()); err != nil {
		log.Fatal(err)
	}
	if _, err = runtime.Reconcile(context.Background()); err != nil {
		log.Fatal(err)
	}
	old := syscall.Umask(0077)
	listener, err := net.Listen("unix", *socket)
	syscall.Umask(old)
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()
	if err = os.Chmod(*socket, 0600); err != nil {
		listener.Close()
		log.Fatal(err)
	}
	srv := &http.Server{Handler: &server{backend: runtime}, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() {
		<-ctx.Done()
		c, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(c)
	}()
	slog.Info("runtime.listening", "socket", *socket, "namespace", *namespace)
	if err = srv.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
