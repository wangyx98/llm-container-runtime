/* entrypoint ARGV... : the entrypoint of the DIND image of the lab (what docker:dind's dockerd-entrypoint.sh does on cgroup v2, without a shell). With a unified cgroup hierarchy it moves
   the processes of the container's cgroup into a child "init" and enables the controllers for the children (a cgroup that has processes cannot hand controllers to its children), then
   it removes a stale pid file and runs ARGV (the dockerd of the image's command line). Static, system calls only. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void put(const char *path, const char *s)
{
    int fd = open(path, O_WRONLY);
    if (fd < 0)
        return;
    if (write(fd, s, strlen(s)) < 0) {
        /* EBUSY, ENOENT...: the cgroup set-up is best effort, dockerd reports what it cannot do */
    }
    close(fd);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "entrypoint: no command\n");
        return 2;
    }
    if (access("/sys/fs/cgroup/cgroup.controllers", R_OK) == 0) {
        char buf[4096], ctl[1024], out[2048] = "";
        FILE *f;
        mkdir("/sys/fs/cgroup/init", 0755);
        f = fopen("/sys/fs/cgroup/cgroup.procs", "r");
        if (f) {
            while (fgets(buf, sizeof(buf), f))
                put("/sys/fs/cgroup/init/cgroup.procs", buf);
            fclose(f);
        }
        f = fopen("/sys/fs/cgroup/cgroup.controllers", "r");
        if (f) {
            if (fgets(ctl, sizeof(ctl), f)) {
                for (char *t = strtok(ctl, " \n"); t; t = strtok(NULL, " \n")) {
                    strcat(out, "+");
                    strcat(out, t);
                    strcat(out, " ");
                }
                put("/sys/fs/cgroup/cgroup.subtree_control", out);
            }
            fclose(f);
        }
    }
    unlink("/var/run/docker.pid");
    unlink("/var/run/docker.sock");
    execv(argv[1], argv + 1);
    perror("entrypoint: exec");
    return 127;
}
