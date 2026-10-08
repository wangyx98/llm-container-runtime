# 1. the sandbox ("pause") image is a setting of containerd's CRI plugin; the key depends on the containerd
#    version (sandbox_image up to 1.7, 'sandbox' under pinned_images in 2.x), so change whichever this file has
sudo python3 - <<'PY'
import re
path = "/run/bench78018481/config.toml"
new = "127.0.0.1:18082/google_containers/pause:3.6"
out, section = [], ""
for line in open(path):
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    if re.match(r"^\s*sandbox_image\s*=", line) or ("pinned_images" in section and re.match(r"^\s*sandbox\s*=", line)):
        line = re.sub(r"=.*", "= '%s'" % new, line) + "\n"
    out.append(line)
open(path, "w").writelines(out)
PY
# 2. containerd reads its configuration when it starts
sudo /var/lib/bench78018481/bin/containerdctl restart
