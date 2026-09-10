package main

import (
	"context"
	"fmt"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/fifo"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const logLimit = 1 << 20

// Runs as an independent collector. gVisor writes to persistent named FIFOs.
// The collector survives adapter SIGKILL and exits when the shim closes its pipes.
// Capture is bounded on disk but both pipes are always drained.
func runLogger(dir string) error {
	if !filepath.IsAbs(dir) {
		return fmt.Errorf("log directory must be absolute")
	}
	outputs := make([]*os.File, 2)
	for i, name := range []string{"stdout", "stderr"} {
		f, err := os.OpenFile(filepath.Join(dir, name), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
		if err != nil {
			return err
		}
		outputs[i] = f
		defer f.Close()
	}
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for i, name := range []string{"stdout", "stderr"} {
		wg.Add(1)
		go func(i int, name string) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
			defer cancel()
			in, err := fifo.OpenFifo(ctx, filepath.Join(dir, name+".pipe"), unix.O_RDONLY, 0600)
			if err != nil {
				errs <- err
				return
			}
			defer in.Close()
			errs <- captureLog(in, outputs[i], filepath.Join(dir, name+".truncated"))
		}(i, name)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			return err
		}
	}
	return atomicJSON(filepath.Join(dir, "logs.done"), true)
}
func captureLog(in io.Reader, out *os.File, marker string) (result error) {
	// Keep draining even on disk/write failure, so a logging failure cannot block
	// the workload. The collector reports failure separately from process exit.
	defer func() {
		if result != nil {
			_, _ = io.Copy(io.Discard, in)
		}
	}()
	stat, err := out.Stat()
	if err != nil {
		return err
	}
	left := int64(logLimit) - stat.Size()
	if left < 0 {
		left = 0
	}
	buf := make([]byte, 32*1024)
	truncated := false
	for {
		n, e := in.Read(buf)
		if n > 0 {
			keep := int64(n)
			if keep > left {
				keep = left
				if !truncated {
					if err = os.WriteFile(marker, []byte("true"), 0600); err != nil {
						return err
					}
					truncated = true
				}
			}
			if keep > 0 {
				if _, err = out.Write(buf[:keep]); err != nil {
					return err
				}
				if err = out.Sync(); err != nil {
					return err
				}
				left -= keep
			}
		}
		if e == io.EOF {
			return out.Sync()
		}
		if e != nil {
			return e
		}
	}
}

// No adapter-owned stream goroutines or FIFO cleanup: the collector owns IO.
type durableIO struct{ config cio.Config }

func (d *durableIO) Config() cio.Config { return d.config }
func (*durableIO) Cancel()              {}
func (*durableIO) Wait()                {}
func (*durableIO) Close() error         { return nil }
func durableCreator(dir string) cio.Creator {
	return func(string) (cio.IO, error) {
		return &durableIO{config: cio.Config{Stdout: filepath.Join(dir, "stdout.pipe"), Stderr: filepath.Join(dir, "stderr.pipe")}}, nil
	}
}
