"""patch_config.py LIB RUN SOCK CNI PAUSE < default.toml > template.toml : containerd's default configuration of the installed version (config version 3 of containerd 2.0-2.2 or 4 of 2.3)
turned into the node's STOCK TEMPLATE: root, state, socket, CNI directories and the runc runtime root are the strings given (the lab passes ${SNAP_COMMON}/... and ${SNAP_DATA}/... as
literal text, which the node's launcher replaces at every start), NRI off, a local sandbox image, runc on the cgroupfs driver, and no registry setting at all (config_path forced
to '' because the default of some versions is not empty)."""
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
    grpc = section == "grpc" or section.endswith("server.v1.grpc")
    ttrpc = section == "ttrpc" or section.endswith("server.v1.ttrpc")
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}'\n"
    elif grpc and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif ttrpc and k == "address":
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
    elif section.endswith(".registry") and k == "config_path":
        line = f"{indent}config_path = ''\n"
    sys.stdout.write(line)
