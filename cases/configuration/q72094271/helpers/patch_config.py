"""patch_config.py LIB RUN SOCK CNI PAUSE < default.toml > config.toml : containerd's default configuration of the installed version moved into its own root, state and socket, NRI off,
a local sandbox image, runc on the cgroupfs driver with a runtime root of its own (RUN/runc, not the /run/containerd/runc that the machine's containerd shares). Nothing else is changed:
in particular base_runtime_spec stays empty and no rlimit is set."""
import re
import sys

lib, run, sock, cni, pause = sys.argv[1:6]
section = ""
runc_options = False
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
        runc_options = section.endswith(".runtimes.runc.options")
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
    elif runc_options and k == "SystemdCgroup":
        line = f"{indent}SystemdCgroup = false\n"
    elif runc_options and k == "Root":
        line = f"{indent}Root = '{run}/runc'\n"
    sys.stdout.write(line)
