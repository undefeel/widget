#!/usr/bin/env bash
# Serial integration, one full acceptance run, then push. Never auto-resets failures.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if [[ $# != 2 || ! $1 =~ ^[0-9]{2}-[0-9]{2}$ || $2 == -* ]]; then
  echo 'Usage: merge.sh NN-NN <worker-branch> (after inspecting diff and review report)' >&2
  exit 2
fi
TASK=$1
BRANCH=$2
if [[ $(git branch --show-current) != main || -n $(git status --porcelain) ]]; then
  echo 'Merge requires the clean primary main checkout; commit plan updates first.' >&2
  exit 1
fi
test -s "plan/specs/$TASK.review.md" || {
  echo "Record and inspect plan/specs/$TASK.review.md before merging." >&2
  exit 1
}
git fetch origin
git merge --ff-only origin/main
git rev-parse --verify "$BRANCH^{commit}" >/dev/null
git diff --stat "HEAD...$BRANCH"
PRE_MERGE_HEAD="$(git rev-parse HEAD)"
git merge --no-ff --no-edit "$BRANCH"
ACCEPT_ARGS=()
if git diff --quiet "$PRE_MERGE_HEAD" HEAD -- Sources Resources tools Tests build.sh; then
  ACCEPT_ARGS=(--tools-only)
fi
if ! plan/tools/accept.sh "${ACCEPT_ARGS[@]}"; then
  echo 'Acceptance failed. Integration commit is local; inspect/fix it before pushing.' >&2
  exit 1
fi
python3 - "$TASK" <<'PY'
from pathlib import Path
import sys
path = Path('plan/STATUS.md')
content = path.read_text()
start, end = '<!-- active:start -->', '<!-- active:end -->'
before, middle = content.split(start, 1)
active, after = middle.split(end, 1)
rows = [line for line in active.strip().splitlines() if not line.startswith('- ' + sys.argv[1] + ' |')]
path.write_text(before + start + '\n' + ('\n'.join(rows) or 'No active dispatches.') + '\n' + end + after
                + '\nMerged ' + sys.argv[1] + '; full acceptance passed. Release/cleanup still required.\n')
PY
git add plan/STATUS.md
git diff --cached --quiet || git commit -m "Record $TASK integration acceptance"
git push origin HEAD:main
echo "Merged and pushed $TASK. Update its stage row, then release and remove its Orca worktree."
