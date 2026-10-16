#!/bin/sh
# Stands in for `claude` / `codex` in tests: reports what it was handed,
# including the key its apiKeyHelper command yields.
python3 - "$@" <<'PY'
import json, os, subprocess, sys
argv = sys.argv[1:]
report = {"argv": argv, "env": {}, "settings": None, "helperKey": None}
for k, v in os.environ.items():
    if k.startswith(("ANTHROPIC_", "AGENTMUX_FAKE_")):
        report["env"][k] = v
if "--settings" in argv:
    report["settings"] = json.loads(argv[argv.index("--settings") + 1])
    helper = report["settings"].get("apiKeyHelper")
    if helper:
        report["helperKey"] = subprocess.run(helper, shell=True, capture_output=True, text=True).stdout
print(json.dumps(report))
sys.exit(int(os.environ.get("FAKE_AGENT_EXIT", "0")))
PY
