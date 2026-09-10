package main

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/containerd/errdefs"
	"golang.org/x/sys/unix"
)

// IPv4-only egress. Deny special-use, metadata, private, benchmark (our pool),
// multicast and reserved destinations both before and after host DNAT.
const protectedIPv4 = "0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4, 168.63.129.16/32"

// conntrack returns exit 1 for an empty deletion as well as real failures.
// Accept only its exact, locale-stable empty result, never a generic exit code.
var noConntrackEntries = regexp.MustCompile(`^conntrack v[0-9.]+ \(conntrack-tools\): 0 flow entries have been deleted\.\s*$`)

func clearConntrack(ctx context.Context, guest string) error {
	ip, err := netip.ParseAddr(guest)
	if err != nil || !ip.Is4() || !netip.MustParsePrefix("198.18.0.0/15").Contains(ip) {
		return fmt.Errorf("invalid sandbox conntrack address")
	}
	for _, direction := range []string{"--orig-src", "--orig-dst"} {
		c := exec.CommandContext(ctx, "conntrack", "-D", "-f", "ipv4", direction, guest)
		c.Env = append(os.Environ(), "LC_ALL=C")
		out, err := c.CombinedOutput()
		if err != nil {
			if exit, ok := err.(*exec.ExitError); ok && exit.ExitCode() == 1 && noConntrackEntries.Match(out) {
				continue
			}
			return fmt.Errorf("conntrack cleanup: %w: %s", err, out)
		}
	}
	return nil
}

type networkRecord struct{ ID, Name, Guest, Gateway, Subnet string }

func (r *Runtime) networkName(id string) string {
	return fmt.Sprintf("scn%x", sha256.Sum256([]byte(r.namespace+"/"+id)))[:15]
}
func (r *Runtime) networkPath(id string) string { return "/run/netns/" + r.networkName(id) }
func (r *Runtime) networkDir() string           { return filepath.Join(r.historyRoot, ".networks") }
func command(ctx context.Context, input, name string, args ...string) ([]byte, error) {
	c := exec.CommandContext(ctx, name, args...)
	c.Stdin = strings.NewReader(input)
	out, err := c.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("%s %v: %w: %s", name, args, err, out)
	}
	return out, nil
}
func networkLock() (func(), error) {
	f, err := os.OpenFile("/run/sandcube-network.lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = unix.Flock(int(f.Fd()), unix.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() { _ = unix.Flock(int(f.Fd()), unix.LOCK_UN); _ = f.Close() }, nil
}
func firewall(n networkRecord) string {
	// A drop in any base chain is final. Host firewalls may further restrict
	// egress, but cannot override these restrictions with an ACCEPT rule.
	return fmt.Sprintf(`table inet %s {
 chain early {
  type filter hook prerouting priority -310; policy accept;
  iifname "%s" meta nfproto != ipv4 counter drop
  iifname "%s" ip saddr != %s counter drop
  iifname "%s" fib daddr type local counter drop
  iifname "%s" ip daddr { %s } counter drop
 }
 chain input {
  type filter hook input priority -10; policy accept;
  iifname "%s" counter drop
 }
 chain forward {
  type filter hook forward priority -10; policy accept;
  iifname "%s" ip daddr { %s } counter drop
  iifname "%s" fib daddr type local counter drop
  iifname "%s" meta l4proto != { tcp, udp, icmp } counter drop
  oifname "%s" meta nfproto != ipv4 counter drop
  oifname "%s" ip daddr != %s counter drop
  oifname "%s" ct state != { established, related } counter drop
 }
 chain nat {
  type nat hook postrouting priority srcnat; policy accept;
  iifname "%s" ip saddr %s masquerade
 }
}
`, n.Name, n.Name, n.Name, n.Guest, n.Name, n.Name, protectedIPv4, n.Name, n.Name, protectedIPv4, n.Name, n.Name, n.Name, n.Name, n.Guest, n.Name, n.Name, n.Guest)
}
func (r *Runtime) setupNetwork(ctx context.Context, id string) error {
	unlock, err := networkLock()
	if err != nil {
		return err
	}
	defer unlock()
	if err = r.removeNetworkLocked(ctx, id); err != nil {
		return err
	}
	if err = os.MkdirAll(r.networkDir(), 0700); err != nil {
		return err
	}
	name := r.networkName(id)
	sum := sha256.Sum256([]byte(name))
	start := int(binary.BigEndian.Uint16(sum[:2])) % 32768
	// A retained firewall also reserves its address after partial teardown.
	// This prevents reuse when a failed conntrack cleanup removed the route.
	firewallState, err := command(ctx, "", "nft", "-j", "list", "ruleset")
	if err != nil {
		return err
	}
	var n networkRecord
	for offset := 0; offset < 32768; offset++ {
		v := ((start + offset) % 32768) * 4
		subnet := fmt.Sprintf("198.%d.%d.%d/30", 18+v/65536, (v/256)%256, v%256)
		routes, e := command(ctx, "", "ip", "-j", "route", "show", "exact", subnet)
		if e != nil {
			return e
		}
		var existing []json.RawMessage
		if e = json.Unmarshal(routes, &existing); e != nil {
			return e
		}
		if len(existing) > 0 {
			continue
		}
		guest := fmt.Sprintf("198.%d.%d.%d", 18+v/65536, (v/256)%256, v%256+2)
		if strings.Contains(string(firewallState), `"`+guest+`"`) {
			continue
		}
		n = networkRecord{ID: id, Name: name, Subnet: subnet, Gateway: fmt.Sprintf("198.%d.%d.%d", 18+v/65536, (v/256)%256, v%256+1), Guest: fmt.Sprintf("198.%d.%d.%d", 18+v/65536, (v/256)%256, v%256+2)}
		break
	}
	if n.ID == "" {
		return fmt.Errorf("sandbox network address pool exhausted")
	}
	// Durable ownership precedes every kernel mutation, including firewall setup.
	if err = atomicJSON(filepath.Join(r.networkDir(), id+".json"), n); err != nil {
		return err
	}
	if _, err = command(ctx, firewall(n), "nft", "-f", "-"); err != nil {
		return err
	}
	commands := [][]string{
		{"ip", "netns", "add", name},
		{"ip", "link", "add", name, "type", "veth", "peer", "name", "eth0", "netns", name},
		{"ip", "addr", "add", n.Gateway + "/30", "dev", name},
		{"ip", "netns", "exec", name, "sysctl", "-qw", "net.ipv6.conf.all.disable_ipv6=1", "net.ipv6.conf.default.disable_ipv6=1"},
		{"ip", "-n", name, "addr", "add", n.Guest + "/30", "dev", "eth0"},
		{"ip", "-n", name, "link", "set", "lo", "up"},
		{"ip", "-n", name, "link", "set", "eth0", "up"},
		{"ip", "-n", name, "route", "add", "default", "via", n.Gateway},
		{"ip", "link", "set", name, "up"},
	}
	for _, args := range commands {
		if _, err = command(ctx, "", args[0], args[1:]...); err != nil {
			return err
		}
	}
	// Resolver is a platform-owned read-only file, never the host's resolver.
	dir := filepath.Join(r.networkDir(), id)
	if err = os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "resolv.conf"), []byte("nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:2\n"), 0644)
}
func (r *Runtime) resolverPath(id string) string {
	return filepath.Join(r.networkDir(), id, "resolv.conf")
}
func (r *Runtime) removeNetwork(ctx context.Context, id string) error {
	unlock, err := networkLock()
	if err != nil {
		return err
	}
	defer unlock()
	return r.removeNetworkLocked(ctx, id)
}
func (r *Runtime) removeNetworkLocked(ctx context.Context, id string) error {
	path := filepath.Join(r.networkDir(), id+".json")
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var n networkRecord
	if err = json.Unmarshal(raw, &n); err != nil {
		return err
	}
	if n.ID != id || n.Name != r.networkName(id) {
		return fmt.Errorf("corrupt network ownership record")
	}
	// Link first: cleanup errors must leave the firewall in place. Missing kernel
	// objects after reboot are normal; command failures are never treated as absence.
	links, err := command(ctx, "", "ip", "-j", "link", "show")
	if err != nil {
		return err
	}
	var list []struct {
		Name string `json:"ifname"`
	}
	if err = json.Unmarshal(links, &list); err != nil {
		return err
	}
	for _, link := range list {
		if link.Name == n.Name {
			if _, err = command(ctx, "", "ip", "link", "delete", n.Name); err != nil {
				return err
			}
		}
	}
	if _, err = os.Stat(r.networkPath(id)); err == nil {
		if _, err = command(ctx, "", "ip", "netns", "delete", n.Name); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if err = clearConntrack(ctx, n.Guest); err != nil {
		return err
	}
	tables, err := command(ctx, "", "nft", "-j", "list", "tables")
	if err != nil {
		return err
	}
	var inventory struct {
		NFTables []struct {
			Table struct{ Family, Name string } `json:"table"`
		} `json:"nftables"`
	}
	if err = json.Unmarshal(tables, &inventory); err != nil {
		return err
	}
	for _, t := range inventory.NFTables {
		if t.Table.Family == "inet" && t.Table.Name == n.Name {
			if _, err = command(ctx, "", "nft", "delete", "table", "inet", n.Name); err != nil {
				return err
			}
		}
	}
	if err = os.RemoveAll(filepath.Join(r.networkDir(), id)); err != nil {
		return err
	}
	return os.Remove(path)
}
func (r *Runtime) reconcileNetworks(ctx context.Context) error {
	paths, err := filepath.Glob(filepath.Join(r.networkDir(), "*.json"))
	if err != nil {
		return err
	}
	for _, path := range paths {
		id := strings.TrimSuffix(filepath.Base(path), ".json")
		if !validID.MatchString(id) {
			return fmt.Errorf("invalid network journal filename")
		}
		sandbox, e := r.Inspect(ctx, id)
		if e != nil && !errdefs.IsNotFound(e) {
			return e
		}
		if e != nil || sandbox.Status != "running" {
			if e = r.removeNetwork(ctx, id); e != nil {
				return e
			}
		}
	}
	return nil
}
