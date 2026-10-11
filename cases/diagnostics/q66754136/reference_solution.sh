#!/bin/bash
# A filter of `ctr images list` is "FIELD OPERATOR VALUE"; the field of the ref is `name` (a field that does not exist, like `ref`, is not an error:
# nothing matches), the operator for "contains" is `~=` (a regular expression, not anchored). The text is plain text, so its regular-expression characters
# are escaped, and the value is a quoted string of the filter language, in which a backslash has to be written twice: `name~="bitnami/kafka:2\\.7\\.0"`.
set -e
cat > /tmp/bench66754136/ref-filter.sh <<'SCRIPT'
#!/bin/bash
# ref-filter.sh TEXT OUTPUT_FILE
python3 - "$1" "$2" <<'PY'
import re
import sys

text, out = sys.argv[1:3]
open(out, "w").write('name~="%s"\n' % re.escape(text).replace("\\", "\\\\"))
PY
SCRIPT
chmod +x /tmp/bench66754136/ref-filter.sh

bash /tmp/bench66754136/ref-filter.sh kafka /tmp/bench66754136/filter.txt
cat /tmp/bench66754136/filter.txt
sudo ctr -a /run/bench66754136/containerd/containerd.sock -n k8s.io images list -q "$(cat /tmp/bench66754136/filter.txt)" 2>/dev/null
