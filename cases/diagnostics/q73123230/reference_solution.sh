#!/bin/bash
# Two stages. The tail input's built-in "cri" multiline parser removes the CRI envelope (timestamp, stream, F/P flag) of every line and
# concatenates the P pieces of a long line with its F piece. A multiline filter then joins the lines of an application event: an event starts with the
# application's timestamp, every line that does not is a continuation of the event before it. The tag has a wildcard, so every file has its own tag and
# the filter keeps the events of the two containers apart.
set -e
FB=/tmp/bench73123230/fluent-bit

cat > $FB/parsers.conf <<'CONF'
[MULTILINE_PARSER]
    name           app_event
    type           regex
    flush_timeout  5000
    rule  "start_state"  "/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2},\d{3}/"           "cont"
    rule  "cont"         "/^(?!\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2},\d{3}).*/"     "cont"
CONF

cat > $FB/pipeline.conf <<'CONF'
[INPUT]
    Name              tail
    Path              /tmp/bench73123230/logs/*.log
    Tag               cri.*
    Read_from_Head    On
    Refresh_Interval  1
    multiline.parser  cri

[FILTER]
    Name                   multiline
    Match                  cri.*
    multiline.key_content  log
    multiline.parser       app_event
CONF

$FB/bin/fluent-bit --dry-run -c $FB/main.conf 2>&1 | tail -3
