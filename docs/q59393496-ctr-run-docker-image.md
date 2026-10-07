# q59393496 — How to run docker images in containerd using ctr in CLI?

Category: Runtime Compatibility (`cases/compatibility/q59393496`)
SO: https://stackoverflow.com/questions/59393496 (page blocked by Cloudflare when the case was built: the original text and any extra argument constraints are UNCONFIRMED; env / argument / mount are the case author's choices)

## Scenario
containerd without Docker; run a Docker-format image with `ctr`. Key `ctr` facts the case tests:
- full image reference required (`docker.io/library/X:tag`, no short name);
- container ID is the 2nd positional argument; `-d` to detach;
- the COMMAND after the ID REPLACES entrypoint and cmd (unlike `docker run IMAGE args`).

## Five stages
1. cleanup — kills this case's private dockerd/containerd/shims/ctr clients, umounts, removes state and work dir (idempotent).
2. setup — builds an offline one-layer Docker-format image (`bench59393496-app:1`, ENTRYPOINT /app, CMD default-arg; /app writes `TOKEN|msg=..|arg=..|argv0=..` to /out/result.txt, exits 17, exit 2 if /out is missing); starts a private containerd + private dockerd (classic image store); imports the image into namespace default.
3. precondition — daemons are the recorded ones, image present with the recorded digest, no container/task in default or moby, output dir empty, a throw-away `ctr run --rm` exits 17 with the expected line.
4. solution — LLM commands.
5. oracle — daemons unchanged, image unchanged, container in namespace default created from the image, task STOPPED with exit status 17 (read from containerd Tasks.Get via gRPC, ctr shows no exit codes), `ctr tasks ls` agrees, result.txt has exactly the expected line and is not newer than the task's exit (forged file rejected). A Docker-made container is rejected with a hint (Docker keeps containers in namespace `moby`).

## Samples (10) and results
| sample | result |
|---|---|
| reference_solution | PASS |
| alt_valid_create_then_start | PASS (`containers create` + `tasks start -d`) |
| no_op_baseline | FAIL (no container) |
| naive_docker_style_args | FAIL (no task: `ping` was taken as the command, container never ran /app) |
| naive_foreground_rm | FAIL (`--rm` deletes container and task) |
| naive_missing_env | FAIL (msg=(unset)) |
| naive_missing_mount | FAIL (exit 2) |
| naive_short_image_name | FAIL (no container) |
| cheat_docker_route | FAIL (container only in Docker) |
| cheat_forged_result_file | FAIL (result.txt newer than task exit) |

Verified in the sandbox as root and as a non-root user with sudo; 3x reference run; cleanup idempotent; no residue.

## Notes
- Fixed-length failure lines: `error_message` is the last 500 chars of oracle stdout.
- `ctr images export` to a pipe (`/dev/stdout`) truncated sometimes; the Docker-route sample exports to a file and retries.
- Known limit: a file forged within 50 ms of the task's exit is indistinguishable from the program's own.
