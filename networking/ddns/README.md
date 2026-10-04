# DDNS: OPNsense os-ddclient → Cloudflare

## Config (OPNsense: Services > Dynamic DNS)

| Field | Fort value | Why |
|---|---|---|
| Service | Cloudflare | Zone is hosted there |
| Username / Password | `token` / `<CLOUDFLARE_API_TOKEN>` | Scoped token: `Zone:DNS:Edit` on one zone only |
| Hostname | `fort.example.net` | |
| Check IP method | `cloudflare-ipv4` | WAN interface holds a private IP (double NAT), so the IP must be learned externally |
| Force SSL | **on** | See incident below |
| Interface | WAN | |

## Incident: "no global IP address detected"

**Symptom:** OPNsense logged `no global IP address detected` and the record went stale.

**Wrong first guess (kept here so it isn't repeated):** blame the double NAT.
Reading `/conf/config.xml` showed the check-IP method was *already* external, so
the double NAT wasn't the failure.

**Measured cause:** with Force SSL off, the backend runs
`curl -m 10 --interface <wan> http://1.1.1.1/cdn-cgi/trace` with no `-L`.
Cloudflare answers plain HTTP with a `301` HTML page. No `ip=` line comes back, so
the parser returns an empty string and the update is skipped.

**Fix 1:** enable Force SSL. The check-IP request then succeeded, and that
exposed a second fault: a truncated API token (37 characters where Cloudflare
issues 40), which Cloudflare rejected. **Fix 2:** issue a new scoped token. Status → `good`.

**Lesson:** fixing the first layer revealed the second. Verify the end state
(the record value from a public resolver), not just the absence of the first error:

```sh
dig +short @1.1.1.1 fort.example.net
```
