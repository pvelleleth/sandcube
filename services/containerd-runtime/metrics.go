package main

import (
	"context"
	"fmt"
	"io/fs"
	"path/filepath"
	"strings"
	"sync/atomic"

	v1 "github.com/containerd/cgroups/v3/cgroup1/stats"
	v2 "github.com/containerd/cgroups/v3/cgroup2/stats"
	"github.com/containerd/typeurl/v2"
)

var runtimeRequests atomic.Uint64
var runtimeFailures atomic.Uint64
var runtimeDurationMillis atomic.Uint64

func (r *Runtime) Metrics(ctx context.Context) (any, error) {
	ctx = r.ctx(ctx)
	inventory, err := r.List(ctx)
	if err != nil {
		return nil, err
	}
	var out strings.Builder
	fmt.Fprintf(&out, "sandcube_runtime_requests_total %d\nsandcube_runtime_failures_total %d\nsandcube_runtime_request_duration_seconds_sum %f\n", runtimeRequests.Load(), runtimeFailures.Load(), float64(runtimeDurationMillis.Load())/1000)
	failures := 0
	for _, sandbox := range inventory {
		c, e := r.load(ctx, sandbox.ID)
		if e != nil {
			failures++
			continue
		}
		info, e := c.Info(ctx)
		if e != nil {
			failures++
			continue
		}
		usage, e := r.client.SnapshotService(info.Snapshotter).Usage(ctx, info.SnapshotKey)
		if e == nil {
			fmt.Fprintf(&out, "sandcube_snapshot_bytes{sandbox_id=%q} %d\n", sandbox.ID, usage.Size)
		} else {
			failures++
		}
		if sandbox.Status != "running" {
			continue
		}
		task, e := c.Task(ctx, nil)
		if e != nil {
			failures++
			continue
		}
		metric, e := task.Metrics(ctx)
		if e != nil {
			failures++
			continue
		}
		data, e := typeurl.UnmarshalAny(metric.Data)
		if e != nil {
			failures++
			continue
		}
		var memory uint64
		var cpu float64
		switch m := data.(type) {
		case *v1.Metrics:
			memory = m.GetMemory().GetUsage().GetUsage()
			cpu = float64(m.GetCPU().GetUsage().GetTotal()) / 1e9
		case *v2.Metrics:
			memory = m.GetMemory().GetUsage()
			cpu = float64(m.GetCPU().GetUsageUsec()) / 1e6
		default:
			failures++
			continue
		}
		fmt.Fprintf(&out, "sandcube_memory_usage_bytes{sandbox_id=%q} %d\nsandcube_cpu_usage_seconds_total{sandbox_id=%q} %f\n", sandbox.ID, memory, sandbox.ID, cpu)
	}
	var bytes int64
	if e := filepath.WalkDir(r.historyRoot, func(path string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if !d.IsDir() {
			i, e := d.Info()
			if e != nil {
				return e
			}
			bytes += i.Size()
		}
		return nil
	}); e != nil {
		failures++
	}
	fmt.Fprintf(&out, "sandcube_process_history_bytes %d\nsandcube_resource_scrape_errors %d\n", bytes, failures)
	r.processMu.Lock()
	ps := make([]*trackedProcess, 0, len(r.processes))
	for _, p := range r.processes {
		ps = append(ps, p)
	}
	r.processMu.Unlock()
	failed := 0
	running := 0
	for _, p := range ps {
		info := p.snapshot()
		if info.Status == "running" {
			running++
		}
		if info.Status == "error" || (info.ExitCode != nil && *info.ExitCode != 0) {
			failed++
		}
	}
	fmt.Fprintf(&out, "sandcube_processes_retained %d\nsandcube_processes_running %d\nsandcube_processes_failed %d\n", len(ps), running, failed)
	return map[string]string{"prometheus": out.String()}, nil
}
