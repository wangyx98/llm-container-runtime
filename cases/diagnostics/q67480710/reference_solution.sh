#!/bin/bash
# The Docker parser reads JSON; a CRI log line is "TIMESTAMP STREAM FLAG TEXT". The tail input needs a parser for that format: the regex parser called
# "cri" (the one the Fluent Bit documentation gives for containerd and CRI-O) captures the stream as `stream` and the text as `log`; the timestamp is
# the record's time. main.conf loads parsers.conf, so the parser is defined there, and the input is told to use it. Read_from_Head On (as before)
# reads the lines already in the files, and tail follows them afterwards.
set -e
FB=/tmp/bench67480710/fluent-bit

cat > $FB/parsers.conf <<'CONF'
[PARSER]
    Name         docker
    Format       json
    Time_Key     time
    Time_Format  %Y-%m-%dT%H:%M:%S.%L
    Time_Keep    On

[PARSER]
    Name         cri
    Format       regex
    Regex        ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[^ ]*) (?<log>.*)$
    Time_Key     time
    Time_Format  %Y-%m-%dT%H:%M:%S.%L%z
CONF

cat > $FB/pipeline.conf <<'CONF'
[INPUT]
    Name              tail
    Tag               kube.*
    Path              /tmp/bench67480710/var/log/containers/*.log
    Parser            cri
    Read_from_Head    On
    Refresh_Interval  5
    Mem_Buf_Limit     5MB
    Skip_Long_Lines   On
CONF

$FB/bin/fluent-bit --dry-run -c $FB/main.conf 2>&1 | tail -3
