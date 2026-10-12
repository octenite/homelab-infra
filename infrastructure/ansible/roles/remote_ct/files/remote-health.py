#!/usr/bin/python3 -I
# Runs every few minutes as the health user from a timer: reports to the
# dead-man's switch when the tunnel is up, and to its failure address when it
# is not. A missing report means the container is down or cut off. The
# address of the switch comes from the environment (a root-only file that
# the service manager reads).
import http.client
import json
import os
import subprocess
import sys
import urllib.parse


def status():
    try:
        out = subprocess.run(
            ["/usr/bin/tailscale", "status", "--json", "--peers=false"],
            capture_output=True, text=True, timeout=20, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, "tailscale status: %s" % e
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


url = urllib.parse.urlsplit(os.environ.get("HEALTH_PING_URL", ""))
if url.scheme != "https" or not url.hostname:
    sys.exit("HEALTH_PING_URL is not set")
ok, text = status()
path = url.path if ok else url.path + "/fail"
try:
    # An HTTPS connection only, whatever the address says: no other scheme can be reached.
    conn = http.client.HTTPSConnection(url.hostname, url.port, timeout=10)
    conn.request("POST", path, body=text.encode()[:1000])
    code = conn.getresponse().status
    if code != 200:
        raise RuntimeError("answer %d" % code)
except Exception as e:  # noqa: BLE001  the reason goes to the journal, nothing else to do
    sys.exit("ping failed: %s (%s)" % (e, text))
print(text)
sys.exit(0 if ok else 1)
