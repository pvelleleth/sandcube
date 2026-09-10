package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unsafe"

	"github.com/containerd/containerd/v2/core/mount"
	"golang.org/x/sys/unix"
)

func TestQuotaABIAndUnsupportedStorage(t *testing.T) {
	if unsafe.Sizeof(fsxattr{}) != 28 || unsafe.Sizeof(diskQuota{}) != 112 {
		t.Fatal("kernel quota ABI mismatch")
	}
	if _, _, err := snapshotQuotaPath([]mount.Mount{{Type: "bind", Source: "/tmp"}}); err == nil {
		t.Fatal("accepted non-overlay snapshot")
	}
	for _, upper := range []string{"relative/123/fs", "/tmp/0/fs", "/tmp/x/fs", "/tmp/4294967296/fs", "/tmp/123/other"} {
		if _, _, err := snapshotQuotaPath([]mount.Mount{{Type: "overlay", Options: []string{"upperdir=" + upper}}}); err == nil {
			t.Fatalf("accepted %s", upper)
		}
	}
	path, id, err := snapshotQuotaPath([]mount.Mount{{Type: "overlay", Options: []string{"lowerdir=/image", "upperdir=/snapshots/123/fs"}}})
	if err != nil || path != "/snapshots/123" || id != 123 {
		t.Fatal(path, id, err)
	}
	if err = enforceQuota(nil, 0, true); err == nil {
		t.Fatal("accepted unlimited storage")
	}
}

func TestNetworkIdentityAndFirewallBoundary(t *testing.T) {
	a := &Runtime{namespace: "one"}
	b := &Runtime{namespace: "two"}
	if a.networkName("sbx_a") == b.networkName("sbx_a") || a.networkName("sbx_a") == a.networkName("sbx_b") {
		t.Fatal("network identities collide")
	}
	if len(a.networkName("sbx_a")) > 15 {
		t.Fatal("invalid Linux interface name")
	}
	n := networkRecord{Name: a.networkName("sbx_a"), Guest: "198.18.0.2"}
	rules := firewall(n)
	for _, guard := range []string{"priority -310", "fib daddr type local counter drop", "meta nfproto != ipv4 counter drop", "ip saddr != 198.18.0.2 counter drop", "ct state != { established, related } counter drop", "169.254.0.0/16", "100.64.0.0/10", "168.63.129.16/32"} {
		if !strings.Contains(rules, guard) {
			t.Fatalf("missing firewall guard: %s", guard)
		}
	}
	if strings.Count(rules, protectedIPv4) != 2 {
		t.Fatal("protected destinations must be checked before and after DNAT")
	}
}

// Optional kernel test: a disposable dedicated XFS/prjquota mount, never /.
func TestKernelProjectQuota(t *testing.T) {
	root := os.Getenv("SANDCUBE_TEST_XFS")
	if root == "" {
		t.Skip("set SANDCUBE_TEST_XFS to a disposable XFS/prjquota mount")
	}
	base, err := os.MkdirTemp(root, "quota-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)
	parent := filepath.Join(base, "2000000001")
	for _, dir := range []string{"fs", "work"} {
		if err = os.MkdirAll(filepath.Join(parent, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	ms := []mount.Mount{{Type: "overlay", Options: []string{"upperdir=" + filepath.Join(parent, "fs")}}}
	if err = enforceQuota(ms, 16, true); err != nil {
		t.Fatal(err)
	}
	device, err := quotaDevice(parent)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = os.RemoveAll(parent)
		q := diskQuota{Version: 1, Flags: 2, Mask: 15, ID: 2000000001}
		_ = quotaCall(device, 0x5804, q.ID, &q)
	}()
	f, err := os.Create(filepath.Join(parent, "fs", "full"))
	if err != nil {
		t.Fatal(err)
	}
	block := make([]byte, 1<<20)
	total := 0
	for total < 32 {
		_, err = f.Write(block)
		if err != nil {
			break
		}
		total++
	}
	f.Close()
	if (!errors.Is(err, unix.EDQUOT) && !errors.Is(err, unix.ENOSPC)) || total > 16 {
		t.Fatalf("root write exceeded project quota: MB=%d error=%v", total, err)
	}
	if err = enforceQuota(ms, 16, false); err != nil {
		t.Fatal(err)
	}
	if err = enforceQuota(ms, 32, false); err == nil {
		t.Fatal("accepted changed quota after recovery")
	}
	if err = os.Remove(filepath.Join(parent, "fs", "full")); err != nil {
		t.Fatal(err)
	}
	// Workdir must share the budget, and root-owned API writes are also charged.
	if err = os.WriteFile(filepath.Join(parent, "work", "full"), make([]byte, 32<<20), 0600); !errors.Is(err, unix.EDQUOT) && !errors.Is(err, unix.ENOSPC) {
		t.Fatalf("work directory bypass: %v", err)
	}
}

func TestConntrackEmptyResultIsNotPermissionFailure(t *testing.T) {
	if !noConntrackEntries.MatchString("conntrack v1.4.8 (conntrack-tools): 0 flow entries have been deleted.\n") {
		t.Fatal("empty result rejected")
	}
	for _, msg := range []string{"Operation failed: permission denied", "conntrack v1.4.8 (conntrack-tools): 0 flow entries have been deleted.\nOperation failed", "conntrack v1.4.8 (conntrack-tools): 1 flow entries have been deleted."} {
		if noConntrackEntries.MatchString(msg) {
			t.Fatal("accepted nonempty/error result")
		}
	}
}

func TestCorruptResourceOwnershipFailsClosed(t *testing.T) {
	r := &Runtime{namespace: "test", historyRoot: t.TempDir()}
	for _, dir := range []string{r.quotaDir(), r.networkDir()} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, raw := range []string{`{broken`, `{"ID":"sbx_other","Parent":"/snapshots/1","Project":1}`, `{"ID":"sbx_test","Parent":"/snapshots/0","Project":0}`} {
		path := filepath.Join(r.quotaDir(), "sbx_test.json")
		if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
			t.Fatal(err)
		}
		if err := r.reclaimQuota(context.Background(), "sbx_test"); err == nil {
			t.Fatal("invalid quota journal accepted")
		}
		if _, err := os.Stat(path); err != nil {
			t.Fatal("lost ownership on failed cleanup")
		}
	}
	for _, raw := range []string{`{broken`, `{"ID":"sbx_test","Name":"host_interface"}`} {
		path := filepath.Join(r.networkDir(), "sbx_test.json")
		if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
			t.Fatal(err)
		}
		if err := r.removeNetworkLocked(context.Background(), "sbx_test"); err == nil {
			t.Fatal("invalid network journal accepted")
		}
		if _, err := os.Stat(path); err != nil {
			t.Fatal("lost ownership on failed cleanup")
		}
	}
}
