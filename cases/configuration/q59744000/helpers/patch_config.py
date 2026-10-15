"""patch_config.py LIB RUN SOCK CNI PAUSE < default.toml > config.toml : containerd's default config moved into its own root, state and socket, NRI off, a local sandbox image, and the runtimes of the lab:
the default runtime runc with the systemd cgroup driver (SystemdCgroup = true: the node is a systemd host) and a second runtime handler runc-cgroupfs with the cgroupfs driver (for the lab's
control only: a pod that asks for it by name, crictl runp --runtime runc-cgroupfs, gets cgroupfs cgroups)."""
import re
import sys

lib, run, sock, cni, pause = sys.argv[1:6]
section = ""
out = []
runc_section = ""
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
        if section.endswith(".runtimes.runc.options"):
            runc_section = section
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}'\n"
    elif section == "grpc" and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif section == "ttrpc" and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        # do not require CAP_SYS_RESOURCE (absent in unprivileged or nested environments)
        line = f"{indent}restrict_oom_score_adj = true\n"
    elif section.endswith(".cni") and k == "bin_dirs":
        line = f"{indent}bin_dirs = ['{cni}/bin']\n"
    elif section.endswith(".cni") and k == "bin_dir" and not re.search(r"=\s*(''|\"\")\s*$", line):
        line = f"{indent}bin_dir = '{cni}/bin'\n"
    elif section.endswith(".cni") and k == "conf_dir":
        line = f"{indent}conf_dir = '{cni}/net.d'\n"
    elif "pinned_images" in section and k == "sandbox":
        line = f"{indent}sandbox = '{pause}'\n"
    elif k == "sandbox_image":
        line = f"{indent}sandbox_image = '{pause}'\n"
    elif section.endswith(".runtimes.runc.options") and k == "SystemdCgroup":
        line = f"{indent}SystemdCgroup = true\n"
    out.append(line)
if not runc_section:
    sys.exit("no [...runtimes.runc.options] section in the default configuration")
base = runc_section[:-len(".runc.options")]
out.append(f"\n[{base}.runc-cgroupfs]\n  runtime_type = 'io.containerd.runc.v2'\n\n  [{base}.runc-cgroupfs.options]\n    SystemdCgroup = false\n")
sys.stdout.write("".join(out))
