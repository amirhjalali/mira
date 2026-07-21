#!/bin/bash
# One-command onboarding for a NEW Mac joining the MIRA fleet. Run from any
# machine with the repo (normally the Pro):
#
#   bash add-machine.sh <id> <ssh-user> <host-or-tailscale-ip> "<Jump name>" [--viewer [laptop-canvas]]
#
# Examples:
#   bash add-machine.sh air13 amir 100.x.y.z "Amir's MacBook Air 13" --viewer laptop-air13
#   bash add-machine.sh studio amir studio.local "Amir's Mac Studio"
#
# Adds the machine to config/machines.json (if absent), authorizes SSH, pushes
# the signed app + config + LaunchAgent via deploy.sh, then prints the short
# list of steps that genuinely need a human.
set -e
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ID="$1"; SSHUSER="$2"; HOST="$3"; JUMPNAME="$4"
ROLE_FLAG="${5:-}"; CANVAS="${6:-}"
[ -n "$ID" ] && [ -n "$SSHUSER" ] && [ -n "$HOST" ] && [ -n "$JUMPNAME" ] || {
  echo "usage: $0 <id> <ssh-user> <host> \"<Jump name>\" [--viewer [laptop-canvas]]" >&2
  exit 2
}

echo "1/4  SSH key (you may be asked for $SSHUSER@$HOST's password once)…"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSHUSER@$HOST" true 2>/dev/null \
  || ssh-copy-id "$SSHUSER@$HOST"

echo "2/4  Registering in config/machines.json…"
python3 - "$ID" "$SSHUSER" "$HOST" "$JUMPNAME" "$ROLE_FLAG" "$CANVAS" <<'PY'
import json, sys
mid, user, host, jump, role, canvas = (sys.argv + [""] * 7)[1:7]
cfg = json.load(open("config/machines.json"))
if any(m["id"] == mid for m in cfg["machines"]):
    print(f"   {mid} already registered — leaving config as is")
else:
    entry = {"id": mid, "jumpName": jump, "host": host, "tailscale": host,
             "user": user, "roles": ["target"], "type": "mac"}
    if role == "--viewer":
        entry["roles"] = ["viewer", "target"]
        entry["laptopCanvas"] = canvas or "laptop-air"
    cfg["machines"].append(entry)
    json.dump(cfg, open("config/machines.json", "w"), indent=2, ensure_ascii=False)
    print(f"   {mid} added")
PY

echo "3/4  Deploying MIRA…"
bash deploy.sh --to "$ID" "$SSHUSER" "$HOST"

echo "4/4  Done. Manual steps that need a human on $ID:"
cat <<EOF
   - Install Jump Desktop Connect and pair it: generate a connect code in any
     viewer's Jump app (+ Add Computer), then on $ID:
       "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect" --connectcode <code>
   - Install Tailscale and sign in (if not already).
   - If it will DRIVE: grant Accessibility to ~/Applications/MIRA.app in
     System Settings, and save Jump connections for its passengers.
   - Commit the config change:  git add config/machines.json && git commit && git push
EOF
