# runc asks for a terminal for the process because config.json says "terminal": true; a job without a
# controlling terminal cannot give it one. The process needs none: its stdout and stderr go to pipes.
sudo python3 - <<'PYEOF'
import json

path = "/tmp/bench55103653/bundle/config.json"
c = json.load(open(path))
c["process"]["terminal"] = False
json.dump(c, open(path, "w"), indent=2)
PYEOF
