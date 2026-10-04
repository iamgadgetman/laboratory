#!/usr/bin/env python3
import json
import logging
import os
import sys
import time
from pathlib import Path

import requests
import yaml

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)

STATES = {"HEALTHY", "DEGRADED", "FAILED_OVER", "RECOVERING"}


def load_config(path="/app/config.yml"):
    with open(path) as f:
        return yaml.safe_load(f)


def read_secret(env_var):
    path = os.environ.get(env_var)
    if path and Path(path).exists():
        return Path(path).read_text().strip()
    return None


def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"state": "HEALTHY", "failures": 0, "successes": 0}


def save_state(path, state):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(state, f)


def health_check(wan_url, internal_url, timeout):
    """
    Returns True only if BOTH checks pass:
    - wan_url: outbound internet check (detects WAN failure)
    - internal_url: Traefik ping (detects service failure)
    """
    wan_ok = False
    svc_ok = False

    try:
        r = requests.get(wan_url, timeout=timeout, allow_redirects=True, verify=True)
        wan_ok = r.status_code in (200, 301, 302)
    except Exception as e:
        log.debug("WAN health check error: %s", e)

    try:
        r = requests.get(internal_url, timeout=timeout, allow_redirects=False, verify=False)
        svc_ok = r.status_code in (200, 301, 302)
    except Exception as e:
        log.debug("Service health check error: %s", e)

    if not wan_ok:
        log.warning("WAN check FAILED (%s)", wan_url)
    if not svc_ok:
        log.warning("Service check FAILED (%s)", internal_url)

    return wan_ok and svc_ok


def cf_get_record_id(zone_id, hostname, token):
    resp = requests.get(
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records",
        headers={"Authorization": f"Bearer {token}"},
        params={"name": hostname, "type": "A"},
        timeout=10,
    )
    resp.raise_for_status()
    records = resp.json().get("result", [])
    return records[0]["id"] if records else None


def cf_update_record(zone_id, record_id, hostname, ip, ttl, token):
    resp = requests.patch(
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"type": "A", "name": hostname, "content": ip, "ttl": ttl},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


def update_all_records(config, target_ip, cf_token):
    zone_id = config["cloudflare_zone_id"]
    ttl = config.get("dns_ttl", 60)
    for hostname in config.get("failover_hostnames", []):
        try:
            record_id = cf_get_record_id(zone_id, hostname, cf_token)
            if not record_id:
                log.warning("No A record found for %s — skipping", hostname)
                continue
            cf_update_record(zone_id, record_id, hostname, target_ip, ttl, cf_token)
            log.info("Updated %s → %s", hostname, target_ip)
        except Exception as e:
            log.error("Failed to update %s: %s", hostname, e)


def send_discord(webhook_url, message):
    if not webhook_url:
        return
    try:
        requests.post(webhook_url, json={"content": message}, timeout=10)
    except Exception as e:
        log.warning("Discord alert failed: %s", e)


def evaluate_state(current, failures, successes, fail_threshold, recover_threshold):
    if current == "HEALTHY":
        if failures >= fail_threshold:
            return "FAILED_OVER"
        if failures >= 1:
            return "DEGRADED"
    elif current == "DEGRADED":
        if successes >= 1:
            return "HEALTHY"
        if failures >= fail_threshold:
            return "FAILED_OVER"
    elif current == "FAILED_OVER":
        if successes >= recover_threshold:
            return "RECOVERING"
    elif current == "RECOVERING":
        if failures >= 1:
            return "FAILED_OVER"
        if successes >= recover_threshold:
            return "HEALTHY"
    return current


def main():
    cfg = load_config()
    cf_token = read_secret("CF_DNS_API_TOKEN_FILE")
    discord_url = read_secret("DISCORD_WEBHOOK_FILE")

    if not cf_token:
        log.error("CF_DNS_API_TOKEN_FILE not set or unreadable — cannot update DNS")

    state_path = cfg.get("state_file", "/var/run/dns-failover/state.json")
    st = load_state(state_path)
    log.info("Starting. State: %s", st["state"])

    fail_threshold = cfg.get("failure_threshold", 5)
    recover_threshold = cfg.get("recovery_threshold", 3)
    interval = cfg.get("check_interval_seconds", 60)
    timeout = cfg.get("health_check_timeout_seconds", 5)
    wan_url = cfg.get("wan_check_url", "https://one.one.one.one/cdn-cgi/trace")
    internal_url = cfg.get("internal_check_url", "http://10.20.3.11:8080/ping")

    while True:
        ok = health_check(wan_url, internal_url, timeout)

        if ok:
            st["failures"] = 0
            st["successes"] = st.get("successes", 0) + 1
        else:
            st["successes"] = 0
            st["failures"] = st.get("failures", 0) + 1

        prev_state = st["state"]
        new_state = evaluate_state(
            prev_state, st["failures"], st["successes"], fail_threshold, recover_threshold
        )

        if new_state != prev_state:
            log.info("State transition: %s → %s", prev_state, new_state)
            st["state"] = new_state

            if new_state == "FAILED_OVER":
                msg = (
                    f":red_circle: **FAILOVER** — Hawk House unreachable after "
                    f"{fail_threshold} checks. DNS → Fort ({cfg['fort_public_ip']})"
                )
                log.warning(msg)
                if cf_token:
                    update_all_records(cfg, cfg["fort_public_ip"], cf_token)
                send_discord(discord_url, msg)

            elif new_state == "HEALTHY" and prev_state in ("FAILED_OVER", "RECOVERING"):
                msg = (
                    f":green_circle: **RECOVERY** — Hawk House back online. "
                    f"DNS → Hawk ({cfg['hawk_public_ip']})"
                )
                log.info(msg)
                if cf_token:
                    update_all_records(cfg, cfg["hawk_public_ip"], cf_token)
                send_discord(discord_url, msg)

            save_state(state_path, st)
        else:
            log.debug(
                "State: %s | ok=%s | failures=%d | successes=%d",
                st["state"], ok, st["failures"], st["successes"],
            )

        time.sleep(interval)


if __name__ == "__main__":
    main()
