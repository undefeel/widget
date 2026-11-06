#!/usr/bin/env python3
"""Repository-local Orca adapters. Python stdlib only; no shell interpolation."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import stat
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / 'plan/.runtime'
MODELS = {
    'luna': ('gpt-6-luna', 'high'),
    'luna-low': ('gpt-6-luna', 'low'),
    'terra': ('gpt-6.1-terra', 'medium'),
    'sol': ('gpt-6.1-sol', 'medium'),
    'sol-low': ('gpt-6.1-sol', 'low'),
    'sol-high': ('gpt-6.1-sol', 'high'),
}
SETTLED = {'succeeded', 'failed', 'cancelled', 'canceled', 'abandoned'}


def fail(message):
    raise RuntimeError(message)


def run(argv, cwd=ROOT, check=True):
    result = subprocess.run([str(x) for x in argv], cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        fail(f"Command failed ({result.returncode}): {argv[0]}\n{result.stderr}\n{result.stdout}")
    return result


def git(*args, cwd=ROOT):
    return run(['git', *args], cwd=cwd).stdout.strip()


def cli():
    if os.environ.get('ORCA_CLI_COMMAND'):
        return os.environ['ORCA_CLI_COMMAND']
    if os.environ.get('ORCA_DEV_REPO_ROOT'):
        return 'orca-dev'
    return 'orca-ide' if sys.platform.startswith('linux') else 'orca'


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as out:
        out.write(data)
        temp = out.name
    os.replace(temp, path)


def receipt(command):
    """Save even failed/unknown mutation receipts before inspecting their shape."""
    result = run([cli(), *command, '--json'], check=False)
    RUNTIME.mkdir(parents=True, exist_ok=True)
    path = RUNTIME / f'{time.time_ns()}-{command[1] if len(command) > 1 else command[0]}.json'
    atomic(path, json.dumps({'argv': command, 'code': result.returncode,
                            'stdout': result.stdout, 'stderr': result.stderr}, indent=2))
    if result.returncode:
        fail(f'Orca failed; receipt: {path}\n{result.stdout}\n{result.stderr}\n'
             'Inspect failedStage, effects, residualResources and recovery. Do not blindly retry.')
    try:
        body = json.loads(result.stdout)
    except ValueError:
        fail(f'Non-JSON Orca response; inspect {path}. Do not repeat a mutation.')
    if body.get('ok') is False:
        fail(f'Orca refused the command; inspect {path}: {body}')
    return body.get('result', body)


def identity(result, kind):
    value = result.get(kind + 'Id')
    nested = result.get(kind)
    if not value and isinstance(nested, dict):
        value = nested.get(kind + 'Id') or nested.get('id')
    if not isinstance(value, str) or not value:
        fail(f'Unknown Orca {kind} receipt schema; inspect saved receipt before retrying.')
    return value


def shared_dir():
    path = Path(git('rev-parse', '--git-common-dir'))
    if not path.is_absolute():
        path = ROOT / path
    path = path.resolve() / 'orca-plan-runtime'
    path.mkdir(parents=True, exist_ok=True)
    return path


@contextlib.contextmanager
def locked():
    with (shared_dir() / 'launch.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def records():
    return [json.loads(p.read_text()) for p in shared_dir().glob('dispatch-*.json')]


def save_record(record):
    atomic(shared_dir() / f"dispatch-{record['dispatchId']}.json",
           json.dumps(record, indent=2))


def show(dispatch):
    result = receipt(['orchestration', 'worker-show', '--dispatch', dispatch, '--full'])
    worker = result.get('worker')
    if not isinstance(worker, dict):
        return result
    observation = result.get('observation') or {}
    projection = result.get('projection') or {}
    return {'state': worker.get('state'),
            'terminal': worker.get('agentTerminalHandle'),
            'workspace': (projection.get('workspace') or {}).get('id') or worker.get('worktreeId'),
            'waitingOnHuman': (observation['agentWait'] is not None) if 'agentWait' in observation else 'unknown'}


def active_records():
    active = []
    for record in records():
        observation = show(record['dispatchId'])
        if observation.get('state') in SETTLED:
            record['settled'] = True
            save_record(record)
        else:
            record['settled'] = False
            save_record(record)
            active.append(record)
    return active


def update_status(local_id, dispatch, role, workspace):
    path = ROOT / 'plan/STATUS.md'
    content = path.read_text()
    start, end = '<!-- active:start -->', '<!-- active:end -->'
    if start not in content or end not in content:
        fail('STATUS.md is missing Active markers. Reconcile the saved launch receipt.')
    before, rest = content.split(start, 1)
    middle, after = rest.split(end, 1)
    rows = [x for x in middle.strip().splitlines() if x != 'No active dispatches.']
    rows.append(f'- {local_id} | {dispatch} | {role} | {workspace}')
    atomic(path, before + start + '\n' + '\n'.join(rows) + '\n' + end + after)


def task_id(local_id):
    mapping = ROOT / 'plan/specs/orca-task-ids.txt'
    matches = [line.split()[1] for line in mapping.read_text().splitlines()
               if line.strip() and not line.lstrip().startswith('#')
               and len(line.split()) == 2 and line.split()[0] == local_id]
    if len(matches) != 1:
        fail(f'Expected exactly one mapping for {local_id} in {mapping}')
    return matches[0]


def run_id():
    match = re.search(r'^Run:\s*(\S+)', (ROOT / 'plan/STATUS.md').read_text(), re.M)
    if not match or match[1] == 'none':
        fail('Create/select an approved Run and set Run: <run_id> in plan/STATUS.md first.')
    return match[1]


def spec(local_id, lead=False):
    if not re.fullmatch(r'\d{2}-\d{2}', local_id):
        fail('Task ID must have the form NN-NN.')
    path = ROOT / f'plan/specs/{local_id}.md'
    content = path.read_text()
    for heading in ['Target', 'Change', 'Constraints', 'Ownership', 'Observable acceptance',
                    'Lead workflow' if lead else 'Self-review']:
        if f'## {heading}' not in content:
            fail(f'{path} needs ## {heading}')
    if 'Follow plan/TESTING.md' not in content:
        fail(f'{path} must require plan/TESTING.md')
    return path


def launch(local_id, role, args, workspace, parent=None, reviewer=False):
    """Reserve capacity before mutation. Unknown outcomes keep the reservation."""
    with locked():
        active = active_records()
        if not parent and not reviewer and any(r['localId'] == local_id and not r['reviewer'] for r in active):
            fail('This Task already has an unsettled implementation Dispatch. Inspect it first.')
        if not reviewer and sum(not r['reviewer'] for r in active) >= 5:
            fail('Five implementation agents are already active across this repository.')
        if parent and not reviewer and sum(r.get('parent') == parent and not r['reviewer']
                                           for r in active) >= 3:
            fail('A lead may have at most three active implementation pieces.')
        pending = shared_dir() / 'unresolved-start.json'
        if pending.exists():
            fail(f'An interrupted/unknown launch requires reconciliation: {pending}')
        atomic(pending, json.dumps({'task': local_id, 'argv': args, 'time': time.time()}))
        result = receipt(['orchestration', 'worker-start', *args])
        dispatch = identity(result, 'dispatch')
        actual_workspace = result.get('workspace') or workspace
        record = {'dispatchId': dispatch, 'localId': local_id, 'role': role,
                  'reviewer': reviewer, 'parent': parent, 'workspace': actual_workspace,
                  'root': str(ROOT), 'created': time.time(), 'continues': 0}
        save_record(record)
        pending.unlink()
        update_status(local_id, dispatch, role, actual_workspace)
    return dispatch


def start(argv):
    if not 1 <= len(argv) <= 3:
        fail('Usage: start.sh NN-NN [luna|luna-low|terra|sol|sol-low|sol-high] [path:<worktree>]')
    local_id = argv[0]
    role = argv[1] if len(argv) > 1 else 'luna'
    if role not in MODELS:
        fail('Unknown executor label.')
    path = spec(local_id, lead=role == 'terra')
    content = path.read_text()
    if re.search(r'^Level:\s*L3\b', content, re.M) and role != 'terra':
        fail('L3 tasks require terra, unless explicitly reclassified after escalation.')
    if re.search(r'^Level:\s*L4\b', content, re.M):
        fail('L4 requires sol analysis and a user decision; no automatic launch.')
    workspace = argv[2] if len(argv) == 3 else 'new-child'
    if workspace != 'new-child' and not workspace.startswith('path:'):
        fail('Existing worktree must use an exact path: selector.')
    model, effort = MODELS[role]
    args = ['--task', task_id(local_id), '--run', run_id(), '--worktree', workspace,
            '--agent', 'codex', '--model', model, '--effort', effort]
    addendum = ROOT / f'plan/specs/{local_id}.addendum.md'
    if workspace == 'new-child':
        if git('status', '--porcelain', '--', '.', ':!plan/STATUS.md'):
            fail('Commit plan/status changes before starting a new-child worktree.')
        git('fetch', 'origin')
        if git('rev-parse', 'HEAD') != git('rev-parse', 'origin/main'):
            fail('Synchronize the integration checkout with origin/main before the wave.')
        args += ['--base-branch', 'origin/main', '--name', f't{local_id}', '--setup', 'skip']
        if addendum.exists():
            args += ['--comment', addendum.read_text()]
    if os.environ.get('RETRY_OF'):
        if workspace == 'new-child':
            fail('RETRY_OF requires path:<same existing worktree>. Inspect/release predecessor first.')
        args += ['--retry-of', os.environ['RETRY_OF']]
    dispatch = launch(local_id, role, args, workspace)
    print(f'{local_id} {dispatch}', flush=True)
    if addendum.exists():
        receipt(['orchestration', 'send', '--to', f'dispatch:{dispatch}',
                 '--subject', f'{local_id} addendum', '--body', addendum.read_text()])


def helper_run(local_id):
    path = RUNTIME / f'lead-{local_id}.json'
    if path.exists():
        return json.loads(path.read_text())['runId']
    result = receipt(['orchestration', 'run-create', '--objective', f'{local_id}: nested implementation and review'])
    value = identity(result, 'run')
    atomic(path, json.dumps({'runId': value}))
    return value


def prompt_launch(local_id, text, role, parent, reviewer=False, child_run=None):
    RUNTIME.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', suffix='.md', dir=RUNTIME, delete=False) as out:
        out.write(text)
        prompt = Path(out.name)
    if reviewer and role == 'gemini':
        agent, model, effort = 'antigravity', 'gemini-3.8-flash-high', None
    else:
        agent, (model, effort) = 'codex', MODELS[role]
    args = ['--spec-file', str(prompt), '--task-title', f'{local_id} {role}',
            '--worktree', 'current', '--agent', agent, '--model', model]
    if effort:
        args += ['--effort', effort]
    if child_run:
        args += ['--run', child_run]
    dispatch = launch(local_id, role, args, 'path:' + str(ROOT), parent, reviewer)
    print(f'{local_id} {dispatch}', flush=True)
    return dispatch


def lead(argv):
    if argv and argv[0] == '--wait-all':
        return wait_all(argv[1:])
    if len(argv) < 2:
        fail('Usage: lead.sh NN-NN implement | part <name> <file> | fix <1|2> <notes-file>')
    local_id, action = argv[:2]
    spec_path = spec(local_id, lead=True)
    plan = ROOT / f'plan/specs/{local_id}.plan.md'
    relative = str(plan.relative_to(ROOT))
    git('ls-files', '--error-unmatch', relative)
    if git('diff', 'HEAD', '--', relative):
        fail('Commit the current lead plan before dispatching a piece.')
    text = spec_path.read_text() + '\n\n' + plan.read_text()
    if action == 'implement' and len(argv) == 2:
        text += '\nImplement only the next explicitly pending sequential piece. Ask if unclear.'
    elif action == 'part' and len(argv) == 4:
        text += '\n\nParallel piece ' + argv[2] + '\n' + Path(argv[3]).read_text()
    elif action == 'fix' and len(argv) == 4 and argv[2] in ('1', '2'):
        text += '\n\nFix round ' + argv[2] + '\n' + Path(argv[3]).read_text()
    else:
        fail('Invalid lead action/arguments; fix rounds are limited to 1 and 2.')
    text += ('\n\nNested worker rules: English only. Do not commit or run full acceptance. '
             'Edit only the selected piece ownership; run focused checks. '
             'Ask the lead on ambiguity. Finish with worker_done and evidence.')
    prompt_launch(local_id, text, 'luna', local_id, child_run=helper_run(local_id))


def snapshot():
    digest = hashlib.sha256()
    digest.update(git('rev-parse', 'HEAD').encode())
    digest.update(git('diff', '--cached', '--binary', '--', '.', ':!plan/STATUS.md').encode())
    paths = run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).stdout.split('\0')
    for name in sorted(set(filter(None, paths))):
        # Coordination receipts and STATUS are written by the coordinator helper.
        if name == 'plan/STATUS.md':
            continue
        path = ROOT / name
        digest.update(name.encode())
        if path.is_symlink():
            digest.update(os.readlink(path).encode())
        elif path.is_file():
            digest.update(str(path.stat().st_mode).encode())
            digest.update(path.read_bytes())
        else:
            digest.update(b'<deleted>')
    return digest.hexdigest()


def review(argv, audit=False):
    if not 1 <= len(argv) <= 2 or (len(argv) == 2 and argv[1] != 'luna'):
        fail('Usage: self-review.sh NN-NN [luna]')
    local_id = argv[0]
    path = ROOT / f'plan/specs/{local_id}.md'
    text = path.read_text()
    role = 'luna' if len(argv) == 2 else 'gemini'
    if audit:
        match = re.search(r'^Review base:\s*`?([^\s`]+)', text, re.M)
        if not match:
            fail('Audit specs must contain Review base: <commit>.')
        base = match[1]
    else:
        base = os.environ.get('REVIEW_BASE', git('merge-base', 'HEAD', 'origin/main'))
    git('rev-parse', '--verify', base + '^{commit}')
    if git('status', '--porcelain', '--', '.', ':!plan/STATUS.md'):
        fail('Commit implementation changes before self-review.')
    prompt = (f'# Read-only {role} review of {local_id}\n\n'
              f'Repository: {ROOT}\nBase commit: {base}\nHead: {git("rev-parse", "HEAD")}\n'
              'Use git diff --stat first, then inspect the complete relevant diff. '
              'Read only: do not edit any file, commit, launch agents, or run mutating commands. '
              'Do not require tests beyond the supplied spec and plan/TESTING.md. '
              'Report blocker/major/minor findings with exact paths, lines, failure scenario, '
              'and relation to the spec; state explicitly when none are found. '
              'Use English. Finish with worker_done and review text.\n\n' + text)
    before = snapshot()
    if audit:
        args = ['--task', task_id(local_id), '--run', run_id(), '--worktree', 'current',
                '--agent', 'antigravity' if role == 'gemini' else 'codex',
                '--model', 'gemini-3.8-flash-high' if role == 'gemini' else 'gpt-6-luna']
        if role == 'luna':
            args += ['--effort', 'high']
        # A mapped audit task's immutable spec contains the full read-only brief.
        if 'Read-only' not in text or 'Review base:' not in text:
            fail('Audit specs must explicitly contain Read-only and Review base:.')
        dispatch = launch(local_id, role, args, 'path:' + str(ROOT), reviewer=True)
        print(f'{local_id} {dispatch}', flush=True)
    else:
        dispatch = prompt_launch(local_id, prompt, role, local_id, reviewer=True,
                                 child_run=helper_run(local_id))
    atomic(RUNTIME / f'review-{dispatch}.json', json.dumps({'snapshot': before, 'base': base}))
    print(f'Review started. Wait and verify using plan/tools/lead.sh --wait-all {dispatch}.',
          file=sys.stderr)


def idle_proven(observation):
    """Only terminal-backed workers can currently provide an explicit idle probe."""
    terminal = observation.get('terminal')
    if not terminal or observation.get('waitingOnHuman') not in (False, 'no'):
        return False
    result = run([cli(), 'terminal', 'wait', '--terminal', terminal, '--for', 'tui-idle',
                  '--timeout-ms', '1', '--json'], check=False)
    if result.returncode:
        return False
    try:
        body = json.loads(result.stdout)
        value = body.get('result', body)
        return value.get('wait', {}).get('satisfied') is True
    except (ValueError, AttributeError):
        return False


def observe_workspace(path):
    """Return a stable filesystem marker, or None if any part was unreadable."""
    excluded = {'.git', 'build', '.runtime', '__pycache__'}
    latest = 0
    pending = [path]
    try:
        root_stat = path.lstat()
        if not stat.S_ISDIR(root_stat.st_mode):
            return None
        latest = root_stat.st_mtime_ns
        while pending:
            directory = pending.pop()
            with os.scandir(directory) as entries:
                for entry in entries:
                    if entry.name in excluded:
                        continue
                    entry_stat = entry.stat(follow_symlinks=False)
                    latest = max(latest, entry_stat.st_mtime_ns)
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(Path(entry.path))
    except OSError:
        return None
    return latest


def clear_observation(record):
    record.pop('fingerprint', None)
    record.pop('unchangedSince', None)


def watchdog():
    """Nudge only: never stop/release/restart a worker on silence."""
    with locked():
        active = active_records()
        for record in active:
            if record['reviewer'] or record.get('continues', 0) >= 3:
                continue
            if not record.get('parent') and any(r.get('parent') == record['localId'] and r['dispatchId'] != record['dispatchId']
                   for r in active):
                continue
            workspace = show(record['dispatchId']).get('workspace') or ''
            # Native receipts encode the path after repo-id::; never guess a checkout.
            if '::' not in workspace:
                clear_observation(record)
                save_record(record)
                continue
            path = Path(workspace.split('::', 1)[1])
            observed = observe_workspace(path)
            if observed is None:
                clear_observation(record)
                save_record(record)
                continue
            mark = run(['git', 'status', '--porcelain'], cwd=path).stdout
            head = git('rev-parse', 'HEAD', cwd=path)
            fingerprint = (mark, head, observed)
            previous = record.get('fingerprint')
            if previous != list(fingerprint):
                record['fingerprint'] = list(fingerprint)
                record['unchangedSince'] = time.time()
            if time.time() - record.get('unchangedSince', time.time()) >= 600:
                observation = show(record['dispatchId'])
                if idle_proven(observation):
                    receipt(['orchestration', 'send', '--to', 'dispatch:' + record['dispatchId'],
                             '--subject', 'Continue assigned work', '--body',
                             'Continue the assigned spec and report worker_done. If blocked, ask your coordinator.'])
                    record['continues'] = record.get('continues', 0) + 1
                    record['unchangedSince'] = time.time()
            save_record(record)


def wait_mail(argv):
    timeout = int(argv[0]) if argv else 540000
    if not 1 <= timeout <= 3600000:
        fail('Timeout must be 1..3600000 milliseconds.')
    watchdog()
    # Peek never consumes mail. One blocking call, no periodic mailbox polling.
    result = receipt(['orchestration', 'check', '--peek', '--wait', '--types',
                      'worker_done,escalation,question', '--timeout-ms', str(timeout)])
    print(json.dumps(result, indent=2), flush=True)
    watchdog()


def wait_all(dispatches):
    if not dispatches:
        fail('Pass at least one exact Dispatch ID.')
    remaining = set(dispatches)
    while remaining:
        for dispatch in list(remaining):
            observation = show(dispatch)
            if observation.get('state') not in SETTLED:
                continue
            report = receipt(['orchestration', 'worker-read', '--dispatch', dispatch, '--limit', '120'])
            print(json.dumps({'dispatchId': dispatch, 'state': observation['state'], 'report': report}, indent=2))
            review_path = RUNTIME / f'review-{dispatch}.json'
            if review_path.exists() and json.loads(review_path.read_text())['snapshot'] != snapshot():
                fail(f'Read-only review {dispatch}: checkout changed. Inspect diff; do not accept automatically.')
            if observation['state'] != 'succeeded':
                fail(f'{dispatch} did not succeed. Inspect the report and handle remaining children.')
            remaining.remove(dispatch)
        if remaining:
            # Return control on ANY mail, including a question, instead of looping on unread mail.
            wait_mail([])
            print('Process the entire returned mail batch, reply to questions, then resume --wait-all.', file=sys.stderr)
            return 75
    return 0


def main():
    if len(sys.argv) < 2:
        fail('Expected start, lead, self-review or wait.')
    handlers = {'start': start, 'lead': lead, 'self-review': review,
                'review': lambda argv: review(argv, audit=True), 'wait': wait_mail}
    if sys.argv[1] not in handlers:
        fail('Unknown operation.')
    return handlers[sys.argv[1]](sys.argv[2:]) or 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
