# Networking

Two sites, each with a single OPNsense edge firewall running FRR. They are
joined by a WireGuard tunnel, with OSPF for reachability and an eBGP session
between router loopbacks. Public names live in Cloudflare and are kept current
with DDNS.

All addresses below are sanitized. See [`docs/SANITIZATION.md`](../docs/SANITIZATION.md).

## Sites at a glance

| | **Hawk House** | **The Fort** |
|---|---|---|
| Edge | OPNsense, `stop` | OPNsense, `halt` |
| Role | Permanent site: critical and SRE services | Lab and heavy-compute site |
| WAN | Public IP directly on the firewall | **Double NAT** behind an ISP GPON router |
| Public name | `hawk.example.net` (stable) | `fort.example.net` (dynamic → DDNS) |
| Site block | `10.20.0.0/22` | `10.40.0.0/22` |
| BGP AS | 65551 | 65552 |
| Loopback / router-ID | `10.255.0.1/32` (`lo1`) | `10.255.0.2/32` (`lo1`) |
| Routing | FRR 10.7.1 (`os-frr`) | FRR 10.7.1 (`os-frr`) |

## Addressing plan

Each site gets a /22, carved into four /24 security zones. Every gateway is
`.100`, never `.1`, so the gateway address is predictable in every zone and
never collides with appliances that default to `.1`.

| Subnet | Site | Zone | Firewall interface | Notable hosts |
|---|---|---|---|---|
| `10.20.0.0/24` | Hawk | LAN | `igb0` | `voyager` (.8) |
| `10.20.1.0/24` | Hawk | Secure / servers | `bridge1` (2 ports) | Swarm nodes `eagle` .8, `falcon` .9, `talon` .10; NAS .7 |
| `10.20.2.0/24` | Hawk | Wi-Fi | `bridge2` (2 ports) | |
| `10.20.3.0/24` | Hawk | DMZ | `bridge3` (2 ports) | Published services |
| `10.40.0.0/24` | Fort | LAN / host management | `igc0` | `union` mgmt (.20) |
| `10.40.1.0/24` | Fort | Transit / Wi-Fi | `igc1` | |
| `10.40.2.0/24` | Fort | DMZ (container services) | `igc2` | Reverse proxy (.18 / .99), one macvlan IP per container |
| `10.40.3.0/24` | Fort | NAS / storage | `igc3` | NAS (.19, .199) |
| `10.99.0.0/29` | both | Inter-site WireGuard transit | `wg0` | Hawk `.1`, Fort `.2` |
| `10.99.1.0/24` | both | WireGuard hub for the cloud VPS and satellite peers | `wg0` | Hawk `.1`, Fort `.2` |

At Hawk the firewall has spare NICs, so each zone is an `if_bridge` of two
physical ports. That gives two switch-less drops per zone without adding a
managed switch.

## Inter-site transport: WireGuard

- One `wg0` per firewall, UDP 51820, MTU 1420, `PersistentKeepalive 25`
  (Fort sits behind NAT, so it has to keep the state alive).
- The site-to-site peer's `AllowedIPs` contains the far side's transit address,
  loopback and four /24s. WireGuard's cryptokey routing acts as a second policy
  layer under OSPF: a route pointing out `wg0` for a prefix not in
  `AllowedIPs` is dropped.
- The same interface also terminates the cloud VPS and a few satellite peers on
  `10.99.1.0/24`.

Example: [`wireguard/wg0-fort.conf.example`](wireguard/wg0-fort.conf.example).
OPNsense configures this through the GUI. The file is the `wg-quick`
equivalent, for readability.

## Routing: OSPF underlay, eBGP between loopbacks

Configs: [`frr/fort-frr.conf`](frr/fort-frr.conf) and
[`frr/hawk-frr.conf`](frr/hawk-frr.conf), captured live and sanitized.

### What actually forwards traffic: WireGuard's kernel routes

Measured 2026-10-04: OPNsense's WireGuard installs a kernel route for every
prefix in the peer's `AllowedIPs`. FRR sees these as `K` routes with distance 0,
which beats every protocol. The inter-site path is therefore effectively
static, and the OSPF and BGP routes below are learned but **not installed**
(`show ip route summary` → `ospf 6, FIB 0`). Handing forwarding to FRR (the
WireGuard *Disable routes* option) is planned. See
[bgp-fix-2026-10.md](bgp-fix-2026-10.md) for how this was found, and the
**[cutover runbook](runbooks/bgp-forwarding-cutover.md)** for the plan.

### OSPF

- Single area 0. Each site advertises its four /24s, its loopback and its
  tunnel addresses.
- **`ip ospf network non-broadcast` on `wg0`, with a static `neighbor … poll-interval 5`.**
  WireGuard is a layer-3 point-to-point interface with no multicast, so the
  default broadcast network type never finds a neighbor. NBMA with an explicit
  neighbor is the fix.
- Every LAN interface is `ip ospf passive`. Subnets are advertised, but nothing
  on a user segment can form an adjacency.
- `area 0.0.0.0 range` (summarize to the /22) and `area … filter-list` are also
  configured, but see Known issue 4.

Measured state, 2026-10-04 (sanitized):

```
halt# show ip ospf neighbor
Neighbor ID   Pri State        Up Time   Dead Time Address    Interface
10.255.0.1      1 Full/Backup  4d09h25m  38.213s   10.99.0.1  wg0:10.99.0.2

halt# show ip route ospf
O   10.20.0.0/24 [110/110] via 10.99.0.1, wg0 onlink, 4d09h25m
O   10.20.1.0/24 [110/20]  via 10.99.0.1, wg0 onlink, 4d09h25m
O   10.20.2.0/24 [110/20]  via 10.99.0.1, wg0 onlink, 4d09h25m
O   10.20.3.0/24 [110/20]  via 10.99.0.1, wg0 onlink, 4d09h25m
O   10.255.0.1/32 [110/10] via 10.99.0.1, wg0 onlink, 4d09h25m
```

### eBGP (policy layer, loopback-to-loopback)

- Private ASNs, one per site: Hawk 65551, Fort 65552.
- Peering runs between loopbacks (`update-source lo1`, `ebgp-multihop`). OSPF
  provides loopback reachability, the classic "IGP underlay, BGP on top" pattern,
  so the session doesn't depend on any single interface address.
- `no bgp default ipv4-unicast`: address families are activated explicitly.
- `bgp listen range` on the transit block allows dynamic peers to join the peer
  group without per-neighbor config.
- Policy is a prefix-list per site plus route-maps named for the direction
  (`Fort`, `Hawk`).

```
halt# show bgp summary
BGP router identifier 10.255.0.2, local AS number 65552
Neighbor     V   AS    MsgRcvd MsgSent  Up/Down  State/PfxRcd PfxSnt Desc
10.255.0.1   4 65551     25979   25981 4d13h07m             4      4 hawk
```

### Known issues (found while writing this up)

1. ~~**The BGP session was up but exchanged zero prefixes.**~~ **Fixed live
   2026-10-04, now 4/4 each way.** Cause: OPNsense's OSPF and BGP pages defined
   route-maps and prefix-lists with the same names, and FRR's single namespace
   let one set overwrite the other. Full write-up:
   [bgp-fix-2026-10.md](bgp-fix-2026-10.md). Still to do: make it permanent in
   the GUI by renaming the colliding OSPF objects.
2. **BGP distance is raised to 200**, so BGP routes stay standby below OSPF.
   (In practice WireGuard's kernel routes win over both; see above.)
3. **`bfd` is enabled with no peers**, so failure detection falls back to OSPF's
   dead interval (~40 s). Adding BFD on the OSPF neighbor is the obvious next step.
4. **The OSPF summarization and filtering are inert.** `area range` and
   `area filter-list` act only on an area border router. With a single area 0
   there is no ABR, so neither does anything. The route table proves it: the
   far site arrives as four /24s, not one /22. Either move each site's LANs
   into its own area, or delete the dead lines.

I'm documenting these deliberately. Finding and explaining your own drift is
the job.

## DDNS

Fort's WAN address is dynamic and double-NATed: the firewall's WAN interface
holds a private address from the ISP router. So DDNS can't read the IP from the
interface; it has to ask an external service.

- OPNsense `os-ddclient`, Cloudflare provider, updating the `fort.example.net` A record.
- Check-IP method: Cloudflare's `/cdn-cgi/trace` over HTTPS. **Force SSL must be
  on.** Over plain HTTP the endpoint answers with a 301. The backend's `curl`
  doesn't follow redirects, so no IP is parsed and the update silently fails.
  That was a real outage. Root cause: [`ddns/README.md`](ddns/README.md).
- Hawk runs the same DDNS setup for `hawk.example.net`, though its address has
  been stable.

**What doesn't follow DDNS yet:** the WireGuard peer entries and the DNS-failover
service's origin list (see [`../automation/`](../automation/)) still hold Fort's
WAN as a literal address. After a Fort WAN change, those have to be updated by
hand (there's a runbook), or the tunnel stays down and failover points at a
dead address. Moving both to resolve `fort.example.net` is on the roadmap.

## Edge services worth mentioning

- **Split-horizon DNS:** Unbound on each firewall answers for
  `*.hawk.example.net` / `*.fort.example.net` only. The public zone lives in
  Cloudflare and is never overridden internally.
- **CrowdSec** on both firewalls, plus the reverse proxies, for L7 blocklists.
- **Reverse proxy:** Traefik at each site with Cloudflare DNS-01 ACME, and
  Authentik SSO in front of most services.

## Verification cheat-sheet

```sh
vtysh -c 'show ip ospf neighbor'        # expect Full over wg0
vtysh -c 'show ip route ospf'           # far-site /24s + loopback via wg0
vtysh -c 'show bgp summary'             # session Established; check PfxRcd/PfxSnt
vtysh -c 'show bgp neighbors 10.255.0.1 advertised-routes'
wg show wg0 latest-handshakes           # epoch < ~2 min old
dig +short @1.1.1.1 fort.example.net    # matches Fort's real WAN
```
