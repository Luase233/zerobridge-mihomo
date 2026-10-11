//go:build windows

package settings

import (
	"net"
	"testing"
)

func TestResolveInterfaceUsesAddressIdentityAfterIndexChange(t *testing.T) {
	c := Config{SourceIP: "10.147.20.2", WindowsIP: "10.147.20.1", InterfaceIndex: 19}
	interfaces := []net.Interface{{Index: 19, Name: "Ethernet", Flags: net.FlagUp}, {Index: 34, Name: "ZeroTier One [fixture]", Flags: net.FlagUp}}
	_, subnet, _ := net.ParseCIDR("10.147.20.1/24")
	subnet.IP = net.ParseIP("10.147.20.1")
	addresses := func(iface net.Interface) ([]net.Addr, error) { return []net.Addr{subnet}, nil }
	if err := resolveInterfaces(&c, interfaces, addresses); err != nil || c.InterfaceIndex != 34 {
		t.Fatalf("stable address identity must replace stale index: index=%d error=%v", c.InterfaceIndex, err)
	}
	interfaces[1].Flags = 0
	if err := resolveInterfaces(&c, interfaces, addresses); err == nil {
		t.Fatal("down ZeroTier interface accepted")
	}
	interfaces[1].Flags = net.FlagUp
	interfaces = append(interfaces, net.Interface{Index: 35, Name: "ZeroTier One [duplicate]", Flags: net.FlagUp})
	if err := resolveInterfaces(&c, interfaces, addresses); err == nil {
		t.Fatal("ambiguous interfaces accepted")
	}
}

func TestResolveInterfaceRejectsWrongSubnetOrAddress(t *testing.T) {
	for _, address := range []string{"10.147.20.3/24", "10.147.20.1/32"} {
		c := Config{SourceIP: "10.147.20.2", WindowsIP: "10.147.20.1", InterfaceIndex: 19}
		ip, subnet, _ := net.ParseCIDR(address)
		subnet.IP = ip
		err := resolveInterfaces(&c, []net.Interface{{Index: 34, Name: "ZeroTier One [fixture]", Flags: net.FlagUp}}, func(net.Interface) ([]net.Addr, error) { return []net.Addr{subnet}, nil })
		if err == nil {
			t.Fatalf("accepted %s", address)
		}
	}
}
