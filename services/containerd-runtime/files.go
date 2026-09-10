package main

// Snapshot mounting and descriptor-based filesystem primitives. No paths are
// passed to a shell or resolved against the host's working directory.
import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"github.com/containerd/errdefs"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/containerd/containerd/v2/core/mount"
	"golang.org/x/sys/unix"
)

const maxFileSize = 16 << 20

var errInvalidPath = errors.New("path must stay within the sandbox, without symlinks or special files")
var errFileTooLarge = errors.New("file exceeds 16 MiB transfer limit")

type FileRequest struct {
	Operation string  `json:"operation"`
	Path      string  `json:"path"`
	Mode      *uint32 `json:"mode,omitempty"`
	Content   string  `json:"content,omitempty"` // base64, internal transport only
}
type FileEntry struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Size int64  `json:"size"`
}
type FileBackend interface {
	File(context.Context, string, FileRequest) (any, error)
}

func sandboxPath(p string) (string, error) {
	if p == "" || len(p) > 4096 || strings.ContainsRune(p, 0) {
		return "", errInvalidPath
	}
	for _, part := range strings.Split(p, "/") {
		if part == ".." {
			return "", errInvalidPath
		}
	}
	return path.Clean(strings.TrimLeft(p, "/") + "/."), nil
}

func confinedOpen(root int, name string, flags int) (int, error) {
	fd, err := unix.Openat2(root, name, &unix.OpenHow{Flags: uint64(flags | unix.O_CLOEXEC), Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS | unix.RESOLVE_NO_XDEV})
	if errors.Is(err, unix.ELOOP) || errors.Is(err, unix.EXDEV) {
		return -1, errInvalidPath
	}
	return fd, err
}

func (r *Runtime) File(ctx context.Context, id string, req FileRequest) (any, error) {
	ctx = r.ctx(ctx)
	c, err := r.load(ctx, id)
	if err != nil {
		return nil, err
	}
	if err = r.checkQuota(ctx, id); err != nil {
		return nil, err
	}
	// Reuse the task's mounted overlay. Mounting the same upper/work dirs a
	// second time gives separate overlay caches and can corrupt live updates.
	if _, taskErr := c.Task(ctx, nil); taskErr == nil {
		root := filepath.Join(r.stateRoot, "io.containerd.runtime.v2.task", r.namespace, id, "rootfs")
		dir, e := os.Open(root)
		if e != nil {
			return nil, e
		}
		defer dir.Close()
		var st unix.Statfs_t
		if e = unix.Fstatfs(int(dir.Fd()), &st); e != nil {
			return nil, e
		}
		if st.Type != unix.OVERLAYFS_SUPER_MAGIC {
			return nil, errors.New("task rootfs is not a mounted overlay")
		}
		return fileAt(int(dir.Fd()), req)
	} else if !errdefs.IsNotFound(taskErr) {
		return nil, taskErr
	}
	info, err := c.Info(ctx)
	if err != nil {
		return nil, err
	}
	mounts, err := r.client.SnapshotService(info.Snapshotter).Mounts(ctx, info.SnapshotKey)
	if err != nil {
		return nil, err
	}
	// Never expose device nodes from an image as host devices.
	for i := range mounts {
		mounts[i].Options = append(mounts[i].Options, "nodev", "nosuid", "noexec")
	}
	var result any
	err = mount.WithTempMount(ctx, mounts, func(root string) error {
		dir, e := os.Open(root)
		if e != nil {
			return e
		}
		defer dir.Close()
		result, e = fileAt(int(dir.Fd()), req)
		return e
	})
	return result, err
}

func fileAt(root int, req FileRequest) (any, error) {
	if req.Mode != nil && *req.Mode > 0777 {
		return nil, errInvalidPath
	}
	name, err := sandboxPath(req.Path)
	if err != nil {
		return nil, err
	}
	if name == "." && req.Operation != "list" {
		return nil, errInvalidPath
	}
	switch req.Operation {
	case "read":
		// Pin and inspect with O_PATH before opening: even opening a device can have
		// effects, and a FIFO could otherwise hang the service.
		fd, e := confinedOpen(root, name, unix.O_PATH)
		if e != nil {
			return nil, e
		}
		defer unix.Close(fd)
		var st unix.Stat_t
		if e = unix.Fstat(fd, &st); e != nil {
			return nil, e
		}
		if st.Mode&unix.S_IFMT != unix.S_IFREG {
			return nil, errInvalidPath
		}
		if st.Size > maxFileSize {
			return nil, errFileTooLarge
		}
		f, e := os.Open(fmt.Sprintf("/proc/self/fd/%d", fd))
		if e != nil {
			return nil, e
		}
		defer f.Close()
		data, e := io.ReadAll(io.LimitReader(f, maxFileSize+1))
		if e != nil {
			return nil, e
		}
		if len(data) > maxFileSize {
			return nil, errFileTooLarge
		}
		return map[string]string{"content": base64.StdEncoding.EncodeToString(data)}, nil
	case "list":
		fd, e := confinedOpen(root, name, unix.O_RDONLY|unix.O_DIRECTORY)
		if e != nil {
			return nil, e
		}
		f := os.NewFile(uintptr(fd), name)
		defer f.Close()
		entries, e := f.ReadDir(10001)
		if e != nil && e != io.EOF {
			return nil, e
		}
		if len(entries) > 10000 {
			return nil, fmt.Errorf("directory exceeds 10000 entries: %w", errFileTooLarge)
		}
		result := make([]FileEntry, 0, len(entries))
		for _, ent := range entries {
			var st unix.Stat_t
			if e := unix.Fstatat(fd, ent.Name(), &st, unix.AT_SYMLINK_NOFOLLOW); e != nil {
				if errors.Is(e, unix.ENOENT) {
					continue
				}
				return nil, e
			}
			kind := "other"
			switch st.Mode & unix.S_IFMT {
			case unix.S_IFREG:
				kind = "file"
			case unix.S_IFDIR:
				kind = "directory"
			case unix.S_IFLNK:
				kind = "symlink"
			}
			result = append(result, FileEntry{Name: ent.Name(), Type: kind, Size: st.Size})
		}
		return map[string]any{"entries": result}, nil
	case "write", "mkdir", "delete":
		parent, e := confinedOpen(root, path.Dir(name), unix.O_RDONLY|unix.O_DIRECTORY)
		if e != nil {
			return nil, e
		}
		defer unix.Close(parent)
		leaf := path.Base(name)
		switch req.Operation {
		case "mkdir":
			mode := uint32(0755)
			if req.Mode != nil {
				mode = *req.Mode
			}
			e = unix.Mkdirat(parent, leaf, mode)
		case "delete":
			// unlinkat never follows the leaf, including if replaced concurrently.
			e = unix.Unlinkat(parent, leaf, 0)
			if errors.Is(e, unix.EISDIR) {
				e = unix.Unlinkat(parent, leaf, unix.AT_REMOVEDIR)
			}
		case "write":
			data, decErr := base64.StdEncoding.DecodeString(req.Content)
			if decErr != nil {
				return nil, errInvalidPath
			}
			if len(data) > maxFileSize {
				return nil, errFileTooLarge
			}
			var st unix.Stat_t
			statErr := unix.Fstatat(parent, leaf, &st, unix.AT_SYMLINK_NOFOLLOW)
			if statErr == nil && st.Mode&unix.S_IFMT != unix.S_IFREG {
				return nil, errInvalidPath
			}
			if statErr != nil && !errors.Is(statErr, unix.ENOENT) {
				return nil, statErr
			}
			mode := uint32(0644)
			if statErr == nil {
				mode = st.Mode & 0777
			}
			if req.Mode != nil {
				mode = *req.Mode
			}
			// Atomic replacement avoids following symlinks/hardlinks and leaves existing
			// contents intact when the upload is rejected or fails partway through.
			tmp := ".sandcube-" + newProcessID()
			fd, openErr := unix.Openat(parent, tmp, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0644)
			if openErr != nil {
				return nil, openErr
			}
			defer unix.Unlinkat(parent, tmp, 0)
			f := os.NewFile(uintptr(fd), tmp)
			_, e = f.Write(data)
			if e == nil {
				e = f.Chmod(os.FileMode(mode))
			}
			if e == nil {
				e = f.Sync()
			}
			closeErr := f.Close()
			if e == nil {
				e = closeErr
			}
			if e == nil {
				e = unix.Renameat(parent, tmp, parent, leaf)
			}
		}
		if e != nil {
			return nil, e
		}
		return map[string]string{"status": "ok"}, nil
	default:
		return nil, errInvalidPath
	}
}
