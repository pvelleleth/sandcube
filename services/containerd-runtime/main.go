package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/errdefs"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

var validID = regexp.MustCompile(`^sbx_[a-zA-Z0-9_-]{1,80}$`)

type server struct {
	backend Backend
	locks   [256]sync.Mutex
}

func (s *server) lock(id string) func() {
	var h byte
	for i := range id {
		h = h*31 + id[i]
	}
	s.locks[h].Lock()
	return s.locks[h].Unlock
}
func respond(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func failure(w http.ResponseWriter, status int, code string, err error) {
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
	timeout := 45 * time.Second
	if strings.HasSuffix(r.URL.Path, "/exec") {
		timeout = time.Hour + 30*time.Second
	}
	if r.URL.Path == "/images/import" {
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
	if r.Method == "POST" && len(parts) == 2 && parts[0] == "images" {
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
		var c Config
		if err = decode(w, r, &c); err != nil {
			failure(w, 400, "INVALID_REQUEST", err)
			return
		}
		if !validID.MatchString(c.ID) || c.Image == "" || len(c.Command) == 0 || c.Command[0] == "" || c.CPU < 1 || c.CPU > 64 || c.MemoryMB < 16 || c.MemoryMB > 262144 || c.Pids < 1 || c.Pids > 65536 {
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
	socket := flag.String("socket", "/run/sandcube/runtime.sock", "private Unix socket")
	address := flag.String("containerd", "/run/sandcube-containerd/containerd.sock", "containerd socket")
	configPath := flag.String("runsc-config", "/etc/sandcube/runsc.toml", "gVisor configuration (overlay2=none required)")
	buildRoot := flag.String("build-root", "/var/lib/sandcube/builds", "shared private build directory")
	namespace := flag.String("namespace", "sandcube", "dedicated containerd namespace")
	flag.Parse()
	if _, err := os.Stat(*configPath); err != nil {
		log.Fatal(err)
	}
	client, err := containerd.New(*address)
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()
	// Refuse to replace any pre-existing filesystem entry, including another live socket.
	if _, err = os.Lstat(*socket); !os.IsNotExist(err) {
		log.Fatal("socket path already exists or is inaccessible")
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
	srv := &http.Server{Handler: &server{backend: &Runtime{client: client, namespace: *namespace, configPath: *configPath, buildRoot: *buildRoot}}, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() {
		<-ctx.Done()
		c, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(c)
	}()
	fmt.Printf("runtime listening on %s (namespace %s)\n", *socket, *namespace)
	if err = srv.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
