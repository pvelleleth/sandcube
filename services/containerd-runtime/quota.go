package main

// XFS project quotas charge the overlay upper AND work directories, including
// API writes while stopped. The snapshotter must live on a dedicated XFS mount
// with prjquota; its numeric snapshot IDs are the reserved project-ID namespace.
import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"github.com/containerd/containerd/v2/core/mount"
	"github.com/containerd/containerd/v2/core/snapshots"
	"github.com/containerd/errdefs"
	"github.com/moby/sys/mountinfo"
	"golang.org/x/sys/unix"
)

type fsxattr struct {
	Flags, Extsize, Nextents, Project, Cowextsize uint32
	Pad                                           [8]byte
}
type diskQuota struct {
	Version                                                    int8
	Flags                                                      int8
	Mask                                                       uint16
	ID                                                         uint32
	BlockHard, BlockSoft, InodeHard, InodeSoft, Blocks, Inodes uint64
	ITimer, BTimer                                             int32
	IWarns, BWarns                                             uint16
	Padding                                                    [4]byte
	RTHard, RTSoft, RTCount                                    uint64
	RTTimer                                                    int32
	RTWarns                                                    uint16
	Pad3                                                       int16
	Pad4                                                       [8]byte
}

func quotaCall(device string, command uintptr, project uint32, value *diskQuota) error {
	p, err := unix.BytePtrFromString(device)
	if err != nil {
		return err
	}
	_, _, errno := unix.Syscall6(unix.SYS_QUOTACTL, (command<<8)|2, uintptr(unsafe.Pointer(p)), uintptr(project), uintptr(unsafe.Pointer(value)), 0, 0)
	if errno != 0 {
		return errno
	}
	return nil
}
func projectAttr(path string, project uint32, set bool) error {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	var attr fsxattr
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), 0x801c581f, uintptr(unsafe.Pointer(&attr))) // FS_IOC_FSGETXATTR
	if errno != 0 {
		return errno
	}
	if set {
		attr.Project = project
		attr.Flags |= 0x200 // FS_XFLAG_PROJINHERIT
		_, _, errno = unix.Syscall(unix.SYS_IOCTL, uintptr(fd), 0x401c5820, uintptr(unsafe.Pointer(&attr)))
		if errno != 0 {
			return errno
		}
	} else if attr.Project != project || attr.Flags&0x200 == 0 {
		return fmt.Errorf("snapshot project quota identity mismatch")
	}
	return nil
}
func snapshotQuotaPath(ms []mount.Mount) (string, uint32, error) {
	for _, m := range ms {
		if m.Type != "overlay" {
			continue
		}
		for _, opt := range m.Options {
			if strings.HasPrefix(opt, "upperdir=") {
				upper := strings.TrimPrefix(opt, "upperdir=")
				parent := filepath.Dir(upper)
				id, err := strconv.ParseUint(filepath.Base(parent), 10, 32)
				if err != nil || id == 0 || !filepath.IsAbs(upper) || filepath.Base(upper) != "fs" {
					return "", 0, fmt.Errorf("unsupported snapshot quota path")
				}
				return parent, uint32(id), nil
			}
		}
	}
	return "", 0, fmt.Errorf("writable overlay snapshot required for disk quota")
}
func quotaDevice(path string) (string, error) {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return "", err
	}
	if st.Type != unix.XFS_SUPER_MAGIC {
		return "", fmt.Errorf("disk quota requires an XFS snapshotter mount with prjquota")
	}
	entries, err := mountinfo.GetMounts(nil)
	if err != nil {
		return "", err
	}
	var best *mountinfo.Info
	for _, entry := range entries {
		if path == entry.Mountpoint || strings.HasPrefix(path, strings.TrimRight(entry.Mountpoint, "/")+"/") {
			if best == nil || len(entry.Mountpoint) > len(best.Mountpoint) {
				best = entry
			}
		}
	}
	if best == nil {
		return "", fmt.Errorf("snapshot mount not found")
	}
	opts := "," + best.VFSOptions + "," + best.Options + ","
	if !strings.Contains(opts, ",prjquota,") && !strings.Contains(opts, ",pquota,") {
		return "", fmt.Errorf("XFS project quota enforcement is not enabled")
	}
	return best.Source, nil
}
func enforceQuota(ms []mount.Mount, diskMB int64, prepare bool) error {
	if diskMB < 16 || diskMB > 1048576 {
		return fmt.Errorf("invalid disk quota")
	}
	parent, project, err := snapshotQuotaPath(ms)
	if err != nil {
		return err
	}
	device, err := quotaDevice(parent)
	if err != nil {
		return err
	}
	want := diskQuota{Version: 1, Flags: 2, Mask: 15, ID: project, BlockHard: uint64(diskMB) * 2048, BlockSoft: uint64(diskMB) * 2048, InodeHard: uint64(diskMB) * 256, InodeSoft: uint64(diskMB) * 256}
	if prepare {
		// Limits first. No container or task can access this snapshot yet.
		if err = quotaCall(device, 0x5804, project, &want); err != nil {
			return fmt.Errorf("set project quota: %w", err)
		}
		for _, path := range []string{parent, filepath.Join(parent, "fs"), filepath.Join(parent, "work")} {
			if err = projectAttr(path, project, true); err != nil {
				return err
			}
		}
	}
	var got diskQuota
	if err = quotaCall(device, 0x5803, project, &got); err != nil {
		return fmt.Errorf("read project quota: %w", err)
	}
	if got.BlockHard != want.BlockHard || got.InodeHard != want.InodeHard {
		return fmt.Errorf("project quota limits do not match sandbox configuration")
	}
	for _, path := range []string{parent, filepath.Join(parent, "fs"), filepath.Join(parent, "work")} {
		if err = projectAttr(path, project, false); err != nil {
			return err
		}
	}
	return nil
}
func (r *Runtime) checkQuota(ctx context.Context, id string) error {
	c, err := r.load(ctx, id)
	if err != nil {
		return err
	}
	info, err := c.Info(ctx)
	if err != nil {
		return err
	}
	disk, err := strconv.ParseInt(info.Labels["sandcube.disk_mb"], 10, 64)
	if err != nil {
		return fmt.Errorf("sandbox has no enforced disk quota; recreate legacy sandbox")
	}
	ms, err := r.client.SnapshotService(info.Snapshotter).Mounts(ctx, info.SnapshotKey)
	if err != nil {
		return err
	}
	return enforceQuota(ms, disk, false)
}

// A durable record bridges snapshot metadata deletion and physical reclamation.
// Containerd may defer directory removal; capacity cannot be released then.
type quotaRecord struct {
	ID, Parent string
	Project    uint32
	DiskMB     int64
}

func (r *Runtime) quotaDir() string { return filepath.Join(r.historyRoot, ".quotas") }
func (r *Runtime) prepareQuota(ctx context.Context, id string, diskMB int64, ms []mount.Mount) error {
	parent, project, err := snapshotQuotaPath(ms)
	if err != nil {
		return err
	}
	if _, err = quotaDevice(parent); err != nil {
		return err
	}
	if err = os.MkdirAll(r.quotaDir(), 0700); err != nil {
		return err
	}
	if err = atomicJSON(filepath.Join(r.quotaDir(), id+".json"), quotaRecord{id, parent, project, diskMB}); err != nil {
		return err
	}
	return enforceQuota(ms, diskMB, true)
}
func (r *Runtime) reclaimQuota(ctx context.Context, id string) error {
	path := filepath.Join(r.quotaDir(), id+".json")
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var rec quotaRecord
	if err = json.Unmarshal(raw, &rec); err != nil {
		return err
	}
	project, parseErr := strconv.ParseUint(filepath.Base(rec.Parent), 10, 32)
	if rec.ID != id || !filepath.IsAbs(rec.Parent) || parseErr != nil || project == 0 || uint32(project) != rec.Project {
		return fmt.Errorf("invalid quota ownership journal")
	}
	device, err := quotaDevice(filepath.Dir(rec.Parent))
	if err != nil {
		return err
	}
	// Never remove directories by a journal path. Only the snapshotter owns them.
	if cleaner, ok := r.client.SnapshotService("overlayfs").(snapshots.Cleaner); ok {
		if err = cleaner.Cleanup(ctx); err != nil && !errdefs.IsNotImplemented(err) {
			return err
		}
	}
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		_, statErr := os.Stat(rec.Parent)
		if statErr != nil && !os.IsNotExist(statErr) {
			return statErr
		}
		var usage diskQuota
		if err = quotaCall(device, 0x5803, rec.Project, &usage); err != nil {
			return err
		}
		if os.IsNotExist(statErr) && usage.Blocks == 0 && usage.Inodes == 0 {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return fmt.Errorf("snapshot storage has not yet been reclaimed")
		case <-tick.C:
		}
	}
	empty := diskQuota{Version: 1, Flags: 2, Mask: 15, ID: rec.Project}
	if err = quotaCall(device, 0x5804, rec.Project, &empty); err != nil {
		return err
	}
	return os.Remove(path)
}
func (r *Runtime) reconcileQuotas(ctx context.Context) error {
	paths, err := filepath.Glob(filepath.Join(r.quotaDir(), "*.json"))
	if err != nil {
		return err
	}
	for _, path := range paths {
		id := strings.TrimSuffix(filepath.Base(path), ".json")
		if !validID.MatchString(id) {
			return fmt.Errorf("invalid quota journal filename")
		}
		if _, err = r.client.LoadContainer(ctx, id); err == nil {
			continue
		} else if !errdefs.IsNotFound(err) {
			return err
		}
		if _, err = r.client.SnapshotService("overlayfs").Stat(ctx, id); err == nil {
			continue
		} else if !errdefs.IsNotFound(err) {
			return err
		}
		if err = r.reclaimQuota(ctx, id); err != nil {
			return err
		}
	}
	return nil
}
