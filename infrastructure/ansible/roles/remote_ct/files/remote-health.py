#!/usr/bin/python3 -I
# Runs every few minutes as the health user from a timer: reports to the
# dead-man's switch when the tunnel is up, and to its failure address when it
# is not. A missing report means the container is down or cut off. The
# address of the switch comes from the environment (a root-only file that
# the service manager reads).
import json
import os
import subprocess
import sys
import urllib.request


def status():
    out = subprocess.run(
        ["/usr/bin/tailscale", "status", "--json", "--peers=false"],
        capture_output=True, text=True, timeout=20, check=False,
    )
    if out.returncode != 0:
        return False, "tailscale status failed: " + out.stderr.strip()[:200]
    d = json.loads(out.stdout)
    problems = []
    if d.get("BackendState") != "Running":
        problems.append("backend " + str(d.get("BackendState")))
    me = d.get("Self") or {}
    if not me.get("Online"):
        problems.append("not online")
    for h in d.get("Health") or []:
        problems.append("health: " + str(h)[:120])
    return not problems, "; ".join(problems) or "running"


url = os.environ.get("HEALTH_PING_URL", "")
if not url.startswith("https://"):
    sys.exit("HEALTH_PING_URL is not set")
ok, text = status()
target = url if ok else url + "/fail"
req = urllib.request.Request(target, data=text.encode()[:1000], method="POST")
try:
    urllib.request.urlopen(req, timeout=10).read()
except Exception as e:  # noqa: BLE001  the reason goes to the journal, nothing else to do
    sys.exit("ping failed: %s (%s)" % (e, text))
print(text)
sys.exit(0 if ok else 1)
