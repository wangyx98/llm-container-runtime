#!/bin/bash
# Reference solution: Fluent Bit's configuration is fine (the record's `message` key is what the stock cri parser makes, the RFC 5424 envelope is valid). "failed to flush chunk" is the syslog output
# failing to send: nothing receives on 127.0.0.1:514/udp (a datagram to it is refused), because the lab's syslog daemon has no `listen udp` line in its configuration. Fluent Bit retries a chunk once
# (Retry_Limit 1) and then drops it, so only what is logged after the receiver is up arrives. The fix is at the receiving end: a listener in the daemon's configuration, and the daemon restarted.
set -e
LIB="/var/lib/bench74310243"
echo 'listen udp 127.0.0.1:514' | sudo tee -a "$LIB/etc/syslogd.conf" >/dev/null
sudo "$LIB/bin/syslogctl" restart
for _ in $(seq 20); do
    [ -s /run/bench74310243/syslog.jsonl ] && break
    sleep 1
done
sudo tail -n 2 /run/bench74310243/syslog.jsonl
