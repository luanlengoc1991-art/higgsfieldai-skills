#!/usr/bin/env bash
# Local mirror of .github/workflows/validate-skills.yml plus the full helper test suite.
# Usage: ./scripts/validate.sh            (run from anywhere)
#        PYTHON=/path/to/python ./scripts/validate.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PYTHONUTF8=1

if [ -z "${PYTHON:-}" ]; then
  for c in "$ROOT/.venv/Scripts/python.exe" "$ROOT/.venv/bin/python" python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "import yaml" >/dev/null 2>&1; then PYTHON="$c"; break; fi
  done
fi
if [ -z "${PYTHON:-}" ]; then
  echo "✗ Need a Python 3 with PyYAML (pip install pyyaml), or set PYTHON=..." >&2
  exit 1
fi
# Helper scripts call `python3`; point it at the interpreter chosen above (it has the test deps,
# and on Windows this avoids the Microsoft Store alias). Needs: pyyaml, pillow, numpy.
if [ -d "$ROOT/.venv" ]; then
  shim="$ROOT/.venv/shim"; mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$PYTHON" > "$shim/python3"; chmod +x "$shim/python3"
  export PATH="$shim:$PATH"
fi
# Keep test temp files inside the repo (gitignored), not on the system drive.
mkdir -p "$ROOT/.venv/tmp"
export TMPDIR="$ROOT/.venv/tmp" TMP="$ROOT/.venv/tmp" TEMP="$ROOT/.venv/tmp"

fail=0
step() { echo; echo "── $1"; }
bad()  { echo "✗ $1"; fail=1; }

step "Frontmatter and name"
for skill_dir in higgsfield-*/; do
  skill_name="${skill_dir%/}"
  skill_md="${skill_dir}SKILL.md"
  [ -f "$skill_md" ] || { bad "$skill_md missing"; continue; }
  "$PYTHON" - "$skill_md" "$skill_name" <<'PY' || fail=1
import sys, yaml, re, pathlib
path = pathlib.Path(sys.argv[1]); expected = sys.argv[2]
text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
m = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
if not m:
    print(f"✗ {path}: no YAML frontmatter"); sys.exit(1)
fm = yaml.safe_load(m.group(1)); desc = fm.get("description", "") or ""
errors = []
if fm.get("name") != expected: errors.append(f"name '{fm.get('name')}' != directory '{expected}'")
if not fm.get("version"): errors.append("version missing")
if not desc: errors.append("description missing")
if len(desc) > 1024: errors.append(f"description exceeds 1024 characters ({len(desc)})")
if "Use when" not in desc: errors.append("description missing 'Use when'")
if "NOT for" not in desc: errors.append("description missing 'NOT for'")
lines = text.count("\n") + 1
for e in errors: print(f"✗ {path}: {e}")
if errors: sys.exit(1)
print(f"✓ {path} (version={fm['version']}, {lines} lines)")
PY
done

step "Version sync"
ROOT_VERSION="$(tr -d '[:space:]' < VERSION)"
for skill_dir in higgsfield-*/; do
  v=$(awk '/^---/{c++; next} c==1 && /^version:/{gsub(/^version:[[:space:]]*/,""); gsub(/[[:space:]]*#.*$/,""); gsub(/[[:space:]]/,""); print; exit}' "${skill_dir}SKILL.md" | tr -d '\r')
  [ "$v" = "$ROOT_VERSION" ] || bad "${skill_dir}SKILL.md version $v != $ROOT_VERSION"
done
for f in .claude-plugin/plugin.json .codex-plugin/plugin.json .cursor-plugin/plugin.json; do
  v=$("$PYTHON" -c "import json; print(json.load(open('$f', encoding='utf-8'))['version'])")
  [ "$v" = "$ROOT_VERSION" ] || bad "$f version $v != $ROOT_VERSION"
done
v=$("$PYTHON" -c "import json; print(json.load(open('.claude-plugin/marketplace.json', encoding='utf-8'))['plugins'][0]['version'])")
[ "$v" = "$ROOT_VERSION" ] || bad "marketplace.json plugins[0].version $v != $ROOT_VERSION"
echo "VERSION $ROOT_VERSION checked"

step "marketplace.json and setup list every skill"
listed=$("$PYTHON" -c "import json; print(' '.join(s.removeprefix('./').rstrip('/') for s in json.load(open('.claude-plugin/marketplace.json', encoding='utf-8'))['plugins'][0]['skills']))")
for skill_dir in higgsfield-*/; do
  s="${skill_dir%/}"
  echo " $listed " | grep -q " $s " || bad "$s not listed in marketplace.json"
  grep -qE "^SKILLS=\(.*\b$s\b" setup || bad "$s not listed in setup SKILLS"
done

step "References resolve, no orphans"
for skill_dir in higgsfield-*/; do
  skill_md="${skill_dir}SKILL.md"
  [ -d "${skill_dir}references" ] || continue
  for ref in $(grep -oE 'references/[a-zA-Z0-9_./-]+\.md' "$skill_md" | sort -u); do
    [ -f "${skill_dir}${ref}" ] || bad "$skill_md links $ref (missing)"
  done
  for f in "${skill_dir}references"/*.md; do
    grep -q "$(basename "$f")" "$skill_md" || bad "orphaned reference $f"
  done
done

step "Self-contained (no ../)"
for skill_dir in higgsfield-*/; do
  grep -nE '(^|[^./])\.\./' "${skill_dir}SKILL.md" && bad "${skill_dir}SKILL.md has ../"
  if [ -d "${skill_dir}references" ]; then
    grep -rnE '(^|[^./])\.\./\.\./' "${skill_dir}references/" && bad "${skill_dir}references has ../../"
  fi
done

step "Script syntax"
for f in higgsfield-*/scripts/*.sh scripts/*.sh setup; do
  [ -f "$f" ] && { bash -n "$f" || bad "bash syntax: $f"; }
done
for f in higgsfield-*/scripts/*.py higgsfield-*/scripts/tests/*.py; do
  [ -f "$f" ] && { "$PYTHON" -m py_compile "$f" 2>&1 || bad "python syntax: $f"; }
done

step "Helper tests"
for t in higgsfield-*/scripts/tests/test_*.py; do
  if out=$("$PYTHON" "$t" 2>&1); then
    echo "✓ $t"
  else
    echo "$out" | tail -25; bad "$t"
  fi
done

echo
if [ "$fail" -eq 0 ]; then echo "✓ ALL CHECKS PASSED"; else echo "✗ SOME CHECKS FAILED"; fi
exit "$fail"
