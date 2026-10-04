# Sanitization map

Every config in this repo is derived from a running system and then rewritten
with the substitutions below. The mapping is **consistent**, so the structure
(which subnet talks to which, what the last octets are) stays real while the
actual addresses do not.

| Real thing | Published as |
|---|---|
| Hawk House site subnets (4 × /24) | `10.20.0.0/24` – `10.20.3.0/24` (summary `10.20.0.0/22`) |
| The Fort site subnets (4 × /24) | `10.40.0.0/24` – `10.40.3.0/24` (summary `10.40.0.0/22`) |
| Inter-site WireGuard transit | `10.99.0.0/29` (Hawk `.1`, Fort `.2`) |
| Cloud VPS WireGuard hub | `10.99.1.0/24` |
| Router loopbacks / router-IDs | `10.255.0.1` (Hawk), `10.255.0.2` (Fort) |
| Public WAN addresses | RFC 5737: Hawk `198.51.100.20`, Fort `203.0.113.10`, VPS `192.0.2.50` |
| Primary domain | `example.net` (`hawk.example.net`, `fort.example.net`) |
| Secondary domain | `example.org` |
| Keys, tokens, passwords | `<PLACEHOLDER_IN_CAPS>` |

Host last octets and the `.100` gateway convention are preserved, because they
are design choices, not secrets. Private ASNs (64512–65534 range) are kept as-is.

Before every commit: `scripts/sanitize-check.sh` must exit 0.
