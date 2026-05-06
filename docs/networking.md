# Networking

How the macOS VM gets to the network. Default is **macvtap bridge over
the host's primary physical NIC**, giving the VM a real LAN IP. Falls
back to user-mode (slirp) if no physical NIC is detected.

## Why macvtap and not user-mode (slirp)

macOS recovery + Setup Assistant + iCloud activation all expect to be
on a "real" network. They probe DHCP, MDNS, and ICMP-Echo to Apple's
servers. User-mode networking (slirp) is a NAT inside QEMU's process —
it provides outgoing TCP/UDP but not full LAN semantics. macOS often
reports "no internet" even when the NAT is technically forwarding
traffic, because the link-local detect heuristics fail.

macvtap creates a virtual NIC bridged off the host's physical
interface. The VM gets:
- A real LAN IP via the host's DHCP server
- Working DNS, MDNS, ICMP, link-local
- Same network namespace your other LAN devices see

This is what production needs. It's also what the install path needs —
recovery downloads the actual macOS image from Apple's CDN, which
requires real network access.

## Auto-detect

`scripts/run.sh` picks the first UP non-virtual interface:

```sh
ip -br link show | awk '$1 !~ /^(lo|docker|br-|veth|macvtap|virbr|tailscale)/ && $2 == "UP" {print $1; exit}'
```

That filters out:
- `lo` — loopback
- `docker*` / `br-*` — Docker bridges
- `veth*` — Docker veth pairs
- `macvtap*` — our own macvtap interface
- `virbr*` — libvirt bridges
- `tailscale*` — Tailscale tunnel

What remains is the physical NIC. On most single-NIC servers this is
`eth0`, `enp1s0`, `enp131s0f0`, etc.

## Pinning a specific interface

Multi-NIC hosts (or hosts where auto-detect picks the wrong one) can
set `HOST_IFACE` explicitly:

```sh
docker run -e HOST_IFACE=enp1s0 ...
```

Or in `compose.yml`:

```yaml
environment:
  - HOST_IFACE=enp1s0
```

Find candidates with:

```sh
ip -br link show
```

## What the QEMU args look like

With `HOST_IFACE` set + macvtap created:

```
-netdev tap,id=net0,fd=3
-device virtio-net-pci,netdev=net0,mac=<auto-from-macvtap>
```

The `fd=3` plumbs the macvtap character device into QEMU. The MAC
address is whatever the macvtap interface generated — random per
container start unless pinned.

`virtio-net-pci` is the device choice for two reasons:
1. macOS has a working virtio-net driver via OpenCore's kext bundle
   (vanilla acidanthera/OpenCorePkg 1.0.7 + standard kexts)
2. Higher throughput than emulated devices like `e1000`

## Why NOT e1000 / e1000-82545em

Apple's built-in `AppleE1000` driver does bind to `e1000` and
`e1000-82545em` in some macOS versions, but it's been flaky in
Sequoia. virtio-net is faster, more compatible, and what production
already uses.

## Why NOT vmxnet3

vmxnet3 needs the VMware Tools / VMnet kext stack. We don't ship those.

## Slirp fallback (CI / laptop dev)

If no physical NIC is detected, `run.sh` falls back to:

```
-netdev user,id=net0,hostfwd=tcp::22220-:22
-device virtio-net-pci,netdev=net0
```

This works for SSH-into-VM workflows on developer laptops where the
host's network is on Wi-Fi (macvtap on Wi-Fi has issues). macOS
recovery may report "no internet" in this mode but background
downloads usually still work via NAT.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `recovery: "you're not connected to the internet"` | slirp fallback active, or wrong HOST_IFACE | Set `HOST_IFACE=<your physical NIC>`; verify `ip -br link show` |
| `ERROR: HOST_IFACE='X' not found inside container` | Specified NIC doesn't exist on the host | Unset `HOST_IFACE` (auto-detect) or fix the name |
| Auto-detect picks the wrong NIC | Multiple physical NICs, the first-UP one isn't internet-facing | Set `HOST_IFACE` explicitly |
| `Failed to add macvtap0` (macvtap can't be created) | Host kernel missing macvtap module | `sudo modprobe macvtap` on the host |
| VM gets a 169.254.x.x link-local | Host's DHCP didn't respond | Check that the physical NIC has a real IP, not isolated. macvtap won't see DHCP if the host doesn't. |
| Wi-Fi host: macvtap unreliable | Wi-Fi drivers often refuse to bridge MAC-promiscuous frames from macvtap | Use slirp fallback (unset HOST_IFACE) for Wi-Fi hosts; or wire in via Ethernet |

## Forensic note

This config was lost briefly during the 2026-05-06 architecture
refactor — the new run.sh defaulted to user-mode slirp, breaking
macOS recovery's network detection mid-install. Reverting to
auto-detect-and-macvtap restored the known-good behavior. See
`incidents/2026-05-06-disk-wipe.md` for the broader architecture
context.

The takeaway: the original launch.sh's networking block had been
tested against actual macOS install over months. Replacing it with
"a simpler default" without verifying against the install path
caused immediate regression. **Don't replace working defaults
without testing the success path.**
