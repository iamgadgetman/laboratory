#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
#  nola-patch — thin wrapper NOLA (or cron, or you) calls to drive patching.
#
#    nola-patch audit                 # report only, changes nothing
#    nola-patch patch                 # apt update + upgrade, no restarts
#    nola-patch full                  # patch + restart inside the window
#    nola-patch full --limit knox     # one host / group
#    nola-patch full --force          # ignore the maintenance window
#    nola-patch status                # print the last run's JSON summary
#
#  Always prints a JSON object on stdout so n8n can parse it directly.
#  Human-readable Ansible output goes to the log file.
#
#  NOTE: the verb is "full", never "reboot" — NOLA's run_command safety
#  filter blocks any command string containing reboot/shutdown/halt.
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ansible lives in a user venv (no root needed to install it), which is not on
# PATH for systemd timers, cron or n8n's non-login SSH sessions. Find it here so
# every caller works without exporting anything.
ANSIBLE_VENV="${ANSIBLE_VENV:-$HOME/.venvs/ansible}"
if ! command -v ansible-playbook >/dev/null 2>&1; then
  [[ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]] && PATH="$ANSIBLE_VENV/bin:$PATH"
fi
export PATH

LOG_DIR="${PATCH_LOG_DIR:-$ROOT/logs}"
LOCK="${PATCH_LOCK:-/tmp/nola-patch.lock}"
REPORT="$ROOT/reports/latest.json"
mkdir -p "$LOG_DIR" "$ROOT/reports"

ACTION="${1:-audit}"; shift || true
LIMIT=""
FORCE="false"
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit|-l) LIMIT="$2"; shift 2 ;;
    --force)    FORCE="true"; shift ;;
    --)         shift; EXTRA+=("$@"); break ;;
    *)          EXTRA+=("$1"); shift ;;
  esac
done

die() { printf '{"ok":false,"error":%s}\n' "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"; exit 1; }

if [[ "$ACTION" == "status" ]]; then
  [[ -f "$REPORT" ]] || die "no report yet - run 'nola-patch audit' first"
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
s=d["summary"]
print(json.dumps({"ok":True,"action":"status","summary":{k:v for k,v in s.items() if k!="discord_fields"},
 "hosts":[{"host":h["host"],"status":h.get("status"),"pending":h.get("pending_count",0),
           "security":h.get("security_count",0),"reboot_required":h.get("reboot_required",False)}
          for h in d["hosts"]]}))' "$REPORT"
  exit 0
fi

case "$ACTION" in
  audit|patch|full) MODE="$ACTION" ;;
  *) die "unknown action '$ACTION' (use: audit | patch | full | status)" ;;
esac

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/patch-$TS.log"

command -v ansible-playbook >/dev/null 2>&1 \
  || die "ansible-playbook not found (looked on PATH and in $ANSIBLE_VENV/bin)"

CMD=(ansible-playbook "$ROOT/playbooks/patch.yml" -e "patch_mode=$MODE")
# --limit applies to every play, including the localhost ones that reset and
# then build the report. Limiting to a host list therefore silently skips the
# reporting play ("skipping: no hosts matched"): the hosts really are patched,
# but latest.json is never rebuilt and nobody is notified, so the dashboard goes
# on showing the previous run as though nothing happened. localhost has to stay
# in scope. It is only in the `control` group, so it never widens the patching.
[[ -n "$LIMIT" ]] && CMD+=(--limit "$LIMIT,localhost")
[[ "$FORCE" == "true" ]] && CMD+=(-e force_reboot=true)
((${#EXTRA[@]})) && CMD+=("${EXTRA[@]}")

# One run at a time. flock returns 1 immediately if another run holds the lock.
exec 9>"$LOCK"
if ! flock -n 9; then
  die "another patch run is already in progress"
fi

cd "$ROOT" || die "cannot cd to $ROOT"
# Braces (not a subshell) so RC set inside is visible afterwards. Do NOT use
# PIPESTATUS here: this group is not a pipeline, so it would report the status
# of the trailing echo — i.e. always 0 — and every failed run would look ok.
RC=0
{
  echo "=== nola-patch $ACTION  limit=${LIMIT:-all}  force=$FORCE  $TS ==="
  "${CMD[@]}"
  RC=$?
  echo "=== exit $RC ==="
} >>"$LOG" 2>&1

# Keep the last 60 logs.
ls -1t "$LOG_DIR"/patch-*.log 2>/dev/null | tail -n +61 | xargs -r rm -f

if [[ -f "$REPORT" ]]; then
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1])); s=d["summary"]
print(json.dumps({"ok": sys.argv[2]=="0","action":sys.argv[3],"log":sys.argv[4],
 "summary":{k:v for k,v in s.items() if k!="discord_fields"},
 "hosts":[{"host":h["host"],"status":h.get("status"),"pending":h.get("pending_count",0),
           "security":h.get("security_count",0),"reboot_required":h.get("reboot_required",False),
           "decision":h.get("reboot_decision")} for h in d["hosts"]]}))' \
    "$REPORT" "$RC" "$ACTION" "$LOG"
else
  die "run finished (rc=$RC) but no report was produced - see $LOG"
fi

exit "$RC"
