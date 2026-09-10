package main

import (
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"golang.org/x/sys/unix"
)

func TestFileOperations(t *testing.T) {
	root := t.TempDir()
	dir, err := os.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer dir.Close()
	fd := int(dir.Fd())
	call := func(op, p string, data []byte) any {
		t.Helper()
		v, e := fileAt(fd, FileRequest{Operation: op, Path: p, Content: base64.StdEncoding.EncodeToString(data)})
		if e != nil {
			t.Fatal(op, p, e)
		}
		return v
	}
	call("mkdir", "/app", nil)
	data := make([]byte, 65536)
	for i := range data {
		data[i] = byte(i)
	}
	call("write", "/app/binary", data)
	result := call("read", "app//./binary", nil).(map[string]string)
	if result["content"] != base64.StdEncoding.EncodeToString(data) {
		t.Fatal("binary corruption")
	}
	call("write", "/app/binary", []byte{})
	if call("read", "/app/binary", nil).(map[string]string)["content"] != "" {
		t.Fatal("overwrite did not truncate")
	}
	if len(call("list", "/app", nil).(map[string]any)["entries"].([]FileEntry)) != 1 {
		t.Fatal("listing")
	}
	if _, err = fileAt(fd, FileRequest{Operation: "delete", Path: "/app"}); !errors.Is(err, unix.ENOTEMPTY) {
		t.Fatal(err)
	}
	call("delete", "/app/binary", nil)
	call("delete", "/app", nil)
	for _, p := range []string{"../outside", "/app/../../outside", "/../outside", "/foo/../bar", "\x00", ""} {
		if _, e := fileAt(fd, FileRequest{Operation: "read", Path: p}); !errors.Is(e, errInvalidPath) {
			t.Fatalf("%q: %v", p, e)
		}
	}
	for _, op := range []string{"write", "delete", "mkdir", "read"} {
		if _, e := fileAt(fd, FileRequest{Operation: op, Path: "/"}); !errors.Is(e, errInvalidPath) {
			t.Fatal(op, e)
		}
	}
}

func TestFileSymlinksAndSpecialFiles(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	sentinel := filepath.Join(outside, "secret")
	os.WriteFile(sentinel, []byte("host"), 0600)
	os.Symlink(outside, filepath.Join(root, "escape"))
	os.Symlink(sentinel, filepath.Join(root, "leaf"))
	os.Symlink("../../", filepath.Join(root, "relative"))
	os.Symlink("loop", filepath.Join(root, "loop"))
	unix.Mkfifo(filepath.Join(root, "fifo"), 0600)
	dir, _ := os.Open(root)
	defer dir.Close()
	fd := int(dir.Fd())
	for _, p := range []string{"escape/secret", "leaf", "relative/etc/passwd", "loop", "fifo"} {
		for _, op := range []string{"read", "write"} {
			if _, e := fileAt(fd, FileRequest{Operation: op, Path: p}); !errors.Is(e, errInvalidPath) {
				t.Fatalf("%s %s: %v", op, p, e)
			}
		}
	}
	for _, op := range []string{"list", "mkdir", "delete"} {
		if _, e := fileAt(fd, FileRequest{Operation: op, Path: "escape/secret"}); !errors.Is(e, errInvalidPath) {
			t.Fatal(op, e)
		}
	}
	// Deleting a leaf symlink is safe and does not delete its target.
	if _, e := fileAt(fd, FileRequest{Operation: "delete", Path: "leaf"}); e != nil {
		t.Fatal(e)
	}
	if b, e := os.ReadFile(sentinel); e != nil || string(b) != "host" {
		t.Fatal("host file changed", e)
	}
}

func TestFileRejectsOversizeWithoutChangingExistingFile(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "file"), []byte("keep"), 0600)
	dir, _ := os.Open(root)
	defer dir.Close()
	_, e := fileAt(int(dir.Fd()), FileRequest{Operation: "write", Path: "file", Content: base64.StdEncoding.EncodeToString(make([]byte, maxFileSize+1))})
	if !errors.Is(e, errFileTooLarge) {
		t.Fatal(e)
	}
	b, _ := os.ReadFile(filepath.Join(root, "file"))
	if string(b) != "keep" {
		t.Fatal("oversized write modified file")
	}
	f, _ := os.Create(filepath.Join(root, "large"))
	f.Truncate(maxFileSize + 1)
	f.Close()
	if _, e = fileAt(int(dir.Fd()), FileRequest{Operation: "read", Path: "large"}); !errors.Is(e, errFileTooLarge) {
		t.Fatal(e)
	}
}

func TestConcurrentSymlinkReplacementCannotEscape(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	os.WriteFile(filepath.Join(outside, "secret"), []byte("host"), 0600)
	os.Mkdir(filepath.Join(root, "safe"), 0700)
	os.WriteFile(filepath.Join(root, "safe", "secret"), []byte("sandbox"), 0600)
	dir, _ := os.Open(root)
	defer dir.Close()
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-done:
				return
			default:
			}
			os.Rename(filepath.Join(root, "safe"), filepath.Join(root, "parked"))
			os.Symlink(outside, filepath.Join(root, "safe"))
			os.Remove(filepath.Join(root, "safe"))
			os.Rename(filepath.Join(root, "parked"), filepath.Join(root, "safe"))
		}
	}()
	for i := 0; i < 1000; i++ {
		v, e := fileAt(int(dir.Fd()), FileRequest{Operation: "read", Path: "safe/secret"})
		if e == nil && v.(map[string]string)["content"] == base64.StdEncoding.EncodeToString([]byte("host")) {
			t.Error("read escaped")
		}
		fileAt(int(dir.Fd()), FileRequest{Operation: "write", Path: "safe/secret", Content: base64.StdEncoding.EncodeToString([]byte("sandbox"))})
	}
	close(done)
	wg.Wait()
	if b, _ := os.ReadFile(filepath.Join(outside, "secret")); string(b) != "host" {
		t.Fatal("write escaped")
	}
}

func TestFileModeAndHardlinkReplacement(t *testing.T) {
	root := t.TempDir()
	original := filepath.Join(root, "original")
	os.WriteFile(original, []byte("original"), 0755)
	os.Link(original, filepath.Join(root, "linked"))
	dir, _ := os.Open(root)
	defer dir.Close()
	req := FileRequest{Operation: "write", Path: "linked", Content: base64.StdEncoding.EncodeToString([]byte("replacement"))}
	if _, e := fileAt(int(dir.Fd()), req); e != nil {
		t.Fatal(e)
	}
	b, _ := os.ReadFile(original)
	if string(b) != "original" {
		t.Fatal("write changed hardlink target")
	}
	st, _ := os.Stat(filepath.Join(root, "linked"))
	if st.Mode().Perm() != 0755 {
		t.Fatal("executable mode lost")
	}
	mode := uint32(0700)
	req.Mode = &mode
	req.Path = "program"
	if _, e := fileAt(int(dir.Fd()), req); e != nil {
		t.Fatal(e)
	}
	st, _ = os.Stat(filepath.Join(root, "program"))
	if st.Mode().Perm() != 0700 {
		t.Fatal("requested mode ignored")
	}
	mode = 04755
	if _, e := fileAt(int(dir.Fd()), req); !errors.Is(e, errInvalidPath) {
		t.Fatal("accepted setuid", e)
	}
}
