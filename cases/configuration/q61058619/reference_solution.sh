#!/bin/bash
set -e

BROKEN_PROFILE_PATH="/etc/crio/broken-seccomp.json"

echo "[solution] fixing the seccomp profile content at $BROKEN_PROFILE_PATH..."
echo "[solution] (this is the file the pod's localhost_ref points at; we replace its"
echo "[solution]  content with a valid, restrictive profile — NOT an allow-all one)"

sudo tee "$BROKEN_PROFILE_PATH" > /dev/null <<'EOF'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_AARCH64"],
  "syscalls": [
    {
      "names": [
        "accept", "accept4", "access", "arch_prctl", "bind", "brk",
        "capget", "capset", "chdir", "chmod", "chown", "clock_getres",
        "clock_gettime", "clone", "close", "connect", "dup", "dup2",
        "epoll_create1", "epoll_ctl", "epoll_wait", "execve", "exit",
        "exit_group", "fcntl", "fstat", "futex", "getcwd", "getdents64",
        "getegid", "geteuid", "getgid", "getpid", "getppid", "getrandom",
        "getsockname", "getsockopt", "gettid", "getuid", "ioctl", "listen",
        "lseek", "madvise", "mkdir", "mmap", "mprotect", "munmap", "nanosleep",
        "open", "openat", "pipe", "pipe2", "poll", "prctl", "pread64",
        "prlimit64", "pwrite64", "read", "readlink", "recvfrom", "recvmsg",
        "rt_sigaction", "rt_sigprocmask", "rt_sigreturn", "sched_yield",
        "select", "sendmsg", "sendto", "set_robust_list", "set_tid_address",
        "setgid", "setgroups", "setsockopt", "setuid", "sigaltstack",
        "setresgid", "setresuid", "setfsgid", "setfsuid", "setreuid", "setregid",
        "socket", "stat", "statfs", "sysinfo", "tgkill", "uname",
        "unlink", "wait4", "write", "writev", "faccessat", "faccessat2",
        "newfstatat", "getdents", "epoll_pwait", "pselect6", "rseq",
        "clock_nanosleep", "clock_nanosleep_time64"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
EOF

echo "[solution] done. No changes were made to crio's daemon config or the pod config —"
echo "[solution] only the referenced seccomp profile's content was fixed."
