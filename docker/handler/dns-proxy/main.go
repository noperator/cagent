package main

import (
	"encoding/binary"
	"log"
	"net"
	"os"
	"os/exec"
	"strings"
	"time"
)

func main() {
	upstream := os.Getenv("MEMBRANE_DNS_RESOLVER")
	if upstream == "" {
		upstream = "1.1.1.1"
	}
	if !strings.Contains(upstream, ":") {
		upstream += ":53"
	}

	// Build hostname allow set from env var
	allowedRaw := os.Getenv("MEMBRANE_ALLOW_HOSTNAMES")
	allowed := make(map[string]bool)
	for _, h := range strings.Split(allowedRaw, "\n") {
		h = strings.TrimSpace(strings.ToLower(h))
		if h != "" && !strings.HasPrefix(h, "#") {
			allowed[h] = true
		}
	}
	log.Printf("dns-proxy: tracking %d hostnames, upstream=%s", len(allowed), upstream)

	addr, err := net.ResolveUDPAddr("udp", "0.0.0.0:53")
	if err != nil {
		log.Fatalf("dns-proxy: resolve listen addr: %v", err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("dns-proxy: listen: %v", err)
	}
	defer conn.Close()
	log.Printf("dns-proxy: listening on UDP :53")

	buf := make([]byte, 4096)
	for {
		n, clientAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("dns-proxy: recv: %v", err)
			continue
		}
		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		go handleQuery(pkt, clientAddr, conn, upstream, allowed)
	}
}

func handleQuery(query []byte, clientAddr *net.UDPAddr, conn *net.UDPConn, upstream string, allowed map[string]bool) {
	upstreamAddr, err := net.ResolveUDPAddr("udp", upstream)
	if err != nil {
		log.Printf("dns-proxy: resolve upstream: %v", err)
		return
	}
	upConn, err := net.DialUDP("udp", nil, upstreamAddr)
	if err != nil {
		log.Printf("dns-proxy: dial upstream: %v", err)
		return
	}
	defer upConn.Close()

	if _, err := upConn.Write(query); err != nil {
		log.Printf("dns-proxy: write upstream: %v", err)
		return
	}

	resp := make([]byte, 4096)
	upConn.SetReadDeadline(time.Now().Add(5 * time.Second))
	rn, err := upConn.Read(resp)
	if err != nil {
		log.Printf("dns-proxy: read upstream: %v", err)
		return
	}
	resp = resp[:rn]

	// Parse response and update nftables before returning to client
	name, ips := extractARecords(resp)
	if name != "" && len(ips) > 0 {
		name = strings.ToLower(strings.TrimRight(name, "."))
		if allowed[name] {
			for _, ip := range ips {
				if err := exec.Command("nft", "add", "element", "ip", "membrane",
					"allowed", "{", ip.String(), "}").Run(); err != nil {
					log.Printf("dns-proxy: nft add %s: %v", ip, err)
				}
			}
			log.Printf("dns-proxy: %s → %v (added to allowed set)", name, ips)
		}
	}

	conn.WriteToUDP(resp, clientAddr)
}

// parseDNSName parses a DNS name from pkt at offset off,
// following compression pointers.
func parseDNSName(pkt []byte, off int) (string, int) {
	var parts []string
	jumped := false
	retOff := off
	seen := make(map[int]bool)
	for off < len(pkt) {
		if seen[off] {
			break
		}
		seen[off] = true
		length := int(pkt[off])
		if length == 0 {
			off++
			if !jumped {
				retOff = off
			}
			break
		}
		if length&0xC0 == 0xC0 {
			if off+1 >= len(pkt) {
				break
			}
			ptr := int(binary.BigEndian.Uint16(pkt[off:off+2])) & 0x3FFF
			if !jumped {
				retOff = off + 2
			}
			jumped = true
			off = ptr
			continue
		}
		off++
		if off+length > len(pkt) {
			break
		}
		parts = append(parts, string(pkt[off:off+length]))
		off += length
	}
	if !jumped {
		retOff = off
	}
	return strings.Join(parts, "."), retOff
}

// extractARecords parses a DNS response and returns the queried name
// and all A record IPs from the answer section.
func extractARecords(pkt []byte) (string, []net.IP) {
	if len(pkt) < 12 {
		return "", nil
	}
	flags := binary.BigEndian.Uint16(pkt[2:4])
	if flags>>15 != 1 {
		return "", nil // not a response
	}
	qdcount := int(binary.BigEndian.Uint16(pkt[4:6]))
	ancount := int(binary.BigEndian.Uint16(pkt[6:8]))

	off := 12
	var queryName string
	for i := 0; i < qdcount; i++ {
		name, newOff := parseDNSName(pkt, off)
		if i == 0 {
			queryName = name
		}
		off = newOff + 4 // skip QTYPE + QCLASS
		if off > len(pkt) {
			return "", nil
		}
	}

	var ips []net.IP
	for i := 0; i < ancount; i++ {
		if off >= len(pkt) {
			break
		}
		_, newOff := parseDNSName(pkt, off)
		off = newOff
		if off+10 > len(pkt) {
			break
		}
		rtype := binary.BigEndian.Uint16(pkt[off : off+2])
		rclass := binary.BigEndian.Uint16(pkt[off+2 : off+4])
		rdlength := int(binary.BigEndian.Uint16(pkt[off+8 : off+10]))
		off += 10
		if off+rdlength > len(pkt) {
			break
		}
		if rtype == 1 && rclass == 1 && rdlength == 4 {
			ips = append(ips, net.IPv4(pkt[off], pkt[off+1], pkt[off+2], pkt[off+3]))
		}
		off += rdlength
	}
	return queryName, ips
}
