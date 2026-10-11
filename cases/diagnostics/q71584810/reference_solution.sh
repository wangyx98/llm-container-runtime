#!/bin/bash
# containerd runs as a systemd service here, so its log is in the journal of its unit (journalctl -u UNIT): it is not a file. A journal cursor
# names a position; the START cursor excludes its own entry (--after-cursor). journalctl has no "until this cursor", but a cursor holds the
# time of its entry (t=, in hexadecimal microseconds), which --until takes. -o cat prints the message alone.
set -e
cat > /tmp/bench71584810/export-pull-log.sh <<'SCRIPT'
#!/bin/bash
# export-pull-log.sh START_CURSOR_FILE END_CURSOR_FILE OUTPUT_FILE
set -e
UNIT=bench71584810-containerd.service
start=$(cat "$1")
end=$(cat "$2")
t=$(printf '%s' "$end" | tr ';' '\n' | sed -n 's/^t=//p')
usec=$((16#$t))
until_ts=$(printf '@%d.%06d' $((usec / 1000000)) $((usec % 1000000)))
sudo journalctl --unit "$UNIT" --after-cursor "$start" --until "$until_ts" -o cat --no-pager > "$3"
SCRIPT
chmod +x /tmp/bench71584810/export-pull-log.sh

bash /tmp/bench71584810/export-pull-log.sh /tmp/bench71584810/cursor.start /tmp/bench71584810/cursor.end /tmp/bench71584810/pull-window.log
