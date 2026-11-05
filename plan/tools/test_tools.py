"""Execute public shell entrypoints in disposable repos against a fake Orca."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

TOOLS = Path(__file__).resolve().parent
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
path = pathlib.Path(os.environ['FAKE_STATE'])
state = json.loads(path.read_text())
state['calls'].append(args)
def value(flag):
    return args[args.index(flag) + 1]
result = {}
code = 0
command = args[1]
if command == 'worker-start':
    if state.get('startFailure'):
        result = {'failedStage': 'agent_readiness', 'dispatchId': 'ctx_failed'}
        code = 1
    else:
        key = 'ctx_' + str(len(state['workers']) + 1)
        state['workers'][key] = {'dispatchId': key, 'state': 'running',
                                'workspace': 'repo::' + os.getcwd(),
                                'waitingOnHuman': False, 'terminal': 'term_' + key}
        result = {'dispatchId': key, 'runId': 'run_test'}
elif command == 'worker-show':
    result = state['workers'][value('--dispatch')]
elif command == 'worker-read':
    result = {'text': 'Review complete: no blocker/major findings.'}
elif command == 'run-create':
    result = {'run': {'id': 'run_nested'}}
elif command == 'check':
    result = {'messages': state.get('messages', [])}
elif command == 'wait':
    result = {'wait': {'satisfied': state.get('idle', False)}}
elif command != 'send':
    raise SystemExit('Unexpected fake command: ' + repr(args))
path.write_text(json.dumps(state))
print(json.dumps({'ok': code == 0, 'result': result}))
sys.exit(code)
'''


class ToolsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='widget tools ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        self.root.mkdir()
        shutil.copytree(TOOLS, self.root / 'plan/tools', ignore=shutil.ignore_patterns('__pycache__'))
        (self.root / 'plan/specs').mkdir()
        (self.root / '.gitignore').write_text('/plan/.runtime/\n__pycache__/\n')
        (self.root / 'plan/STATUS.md').write_text('Run: run_test\n<!-- active:start -->\nNo active dispatches.\n<!-- active:end -->\n')
        mapping = []
        for number in range(1, 8):
            task = f'01-{number:02}'
            mapping.append(f'{task} task_{number}')
            (self.root / f'plan/specs/{task}.md').write_text(
                'Level: L2\n' + '\n'.join('## ' + h for h in [
                    'Target', 'Change', 'Constraints', 'Ownership', 'Observable acceptance', 'Self-review'])
                + '\nFollow plan/TESTING.md\n')
        (self.root / 'plan/specs/orca-task-ids.txt').write_text('\n'.join(mapping))
        self.command('git', 'init', '-b', 'main')
        self.command('git', 'config', 'user.name', 'Tool Test')
        self.command('git', 'config', 'user.email', 'test@example.invalid')
        self.commit()
        remote = Path(self.temp.name) / 'remote.git'
        self.command('git', 'init', '--bare', str(remote))
        self.command('git', 'remote', 'add', 'origin', str(remote))
        self.command('git', 'push', '-u', 'origin', 'main')
        self.fake = Path(self.temp.name) / 'fake orca'
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.state_file = Path(self.temp.name) / 'state.json'
        self.state_file.write_text(json.dumps({'calls': [], 'workers': {}}))
        self.env = dict(os.environ, ORCA_CLI_COMMAND=str(self.fake), FAKE_STATE=str(self.state_file))
        self.env.pop('RETRY_OF', None)

    def command(self, *args):
        result = subprocess.run(args, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result.stdout.strip()

    def commit(self):
        self.command('git', 'add', '.')
        self.command('git', 'commit', '-m', 'fixture')

    def invoke(self, script, *args, code=0, env=None):
        result = subprocess.run(['bash', str(self.root / f'plan/tools/{script}.sh'), *args],
                                cwd=self.root, env=env or self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def state(self, **changes):
        value = json.loads(self.state_file.read_text())
        value.update(changes)
        self.state_file.write_text(json.dumps(value))
        return value

    def calls(self, operation):
        return [c for c in self.state()['calls'] if c[1] == operation]

    def existing_start(self, task='01-01', role='luna', **kwargs):
        return self.invoke('start', task, role, 'path:' + str(self.root), **kwargs)

    def test_start_uses_full_model_and_updates_status(self):
        result = self.existing_start()
        self.assertIn('01-01 ctx_1', result.stdout)
        call = self.calls('worker-start')[0]
        self.assertEqual(call[call.index('--model') + 1], 'gpt-6-luna')
        self.assertEqual(call[call.index('--effort') + 1], 'high')
        self.assertEqual(call[call.index('--task') + 1], 'task_1')
        self.assertIn('ctx_1', (self.root / 'plan/STATUS.md').read_text())

    def test_new_children_use_origin_main_and_allow_status_updates(self):
        self.invoke('start', '01-01')
        self.invoke('start', '01-02')
        for call in self.calls('worker-start'):
            self.assertEqual(call[call.index('--base-branch') + 1], 'origin/main')
            self.assertEqual(call[call.index('--worktree') + 1], 'new-child')

    def test_addendum_is_exact_argument_and_no_comment_on_existing(self):
        body = 'Fix "quoted text"\n`do not execute`; $(touch forbidden)\n'
        (self.root / 'plan/specs/01-01.addendum.md').write_text(body)
        self.existing_start()
        self.assertNotIn('--comment', self.calls('worker-start')[0])
        send = self.calls('send')[0]
        self.assertEqual(send[send.index('--body') + 1], body)
        self.assertFalse((self.root / 'forbidden').exists())

    def test_failure_retains_receipt_and_blocks_fresh_mutation(self):
        self.state(startFailure=True)
        self.existing_start(code=1)
        self.assertTrue(list((self.root / 'plan/.runtime').glob('*worker-start.json')))
        self.state(startFailure=False)
        self.existing_start('01-02', code=1)
        self.assertEqual(len(self.calls('worker-start')), 1)

    def test_retry_requires_same_existing_worktree(self):
        env = dict(self.env, RETRY_OF='ctx_failed')
        self.invoke('start', '01-01', 'luna', code=1, env=env)
        self.existing_start(env=env)
        call = self.calls('worker-start')[0]
        self.assertEqual(call[call.index('--retry-of') + 1], 'ctx_failed')

    def test_global_limit_and_duplicate_task_guard(self):
        self.existing_start()
        self.existing_start(code=1)
        for task in ('01-02', '01-03', '01-04', '01-05'):
            self.existing_start(task)
        self.existing_start('01-06', code=1)
        self.assertEqual(len(self.calls('worker-start')), 5)

    def test_settled_workers_free_capacity(self):
        self.existing_start()
        state = self.state()
        state['workers']['ctx_1']['state'] = 'succeeded'
        self.state(**state)
        self.existing_start()
        self.assertEqual(len(self.calls('worker-start')), 2)

    def test_reopened_dispatch_is_counted_again(self):
        self.existing_start()
        state = self.state()
        state['workers']['ctx_1']['state'] = 'succeeded'
        self.state(**state)
        self.invoke('wait', '1')
        state = self.state()
        state['workers']['ctx_1']['state'] = 'running'
        self.state(**state)
        self.existing_start(code=1)
        self.assertEqual(len(self.calls('worker-start')), 1)

    def test_gemini_and_luna_review_flags(self):
        self.invoke('self-review', '01-01')
        self.invoke('self-review', '01-01', 'luna')
        first, second = self.calls('worker-start')
        self.assertEqual(first[first.index('--agent') + 1], 'antigravity')
        self.assertEqual(first[first.index('--model') + 1], 'gemini-3.8-flash-high')
        self.assertNotIn('--effort', first)
        self.assertEqual(second[second.index('--model') + 1], 'gpt-6-luna')
        prompt = Path(first[first.index('--spec-file') + 1]).read_text()
        self.assertIn('Read only:', prompt)
        self.assertIn('Do not require tests beyond', prompt)

    def test_mapped_audit_uses_existing_task_in_current_run(self):
        path = self.root / 'plan/specs/01-01.md'
        path.write_text(path.read_text() + '\nRead-only\nReview base: origin/main\n')
        self.commit()
        self.invoke('review', '01-01')
        call, = self.calls('worker-start')
        self.assertEqual(call[call.index('--task') + 1], 'task_1')
        self.assertEqual(call[call.index('--run') + 1], 'run_test')
        self.assertNotIn('--spec-file', call)

    def test_wait_peeks_one_long_batch_and_never_consumes(self):
        self.invoke('wait')
        call, = self.calls('check')
        self.assertIn('--peek', call)
        self.assertIn('--wait', call)
        self.assertEqual(call[call.index('--timeout-ms') + 1], '540000')

    def test_wait_all_yields_mail_instead_of_spinning(self):
        self.existing_start()
        self.state(messages=[{'type': 'question', 'body': 'Clarify ownership'}])
        result = self.invoke('lead', '--wait-all', 'ctx_1', code=75)
        self.assertIn('Clarify ownership', result.stdout)
        self.assertEqual(len(self.calls('check')), 1)

    def test_review_detects_checkout_mutation(self):
        self.invoke('self-review', '01-01')
        state = self.state()
        state['workers']['ctx_1']['state'] = 'succeeded'
        self.state(**state)
        (self.root / 'unexpected.txt').write_text('changed')
        result = self.invoke('lead', '--wait-all', 'ctx_1', code=1)
        self.assertIn('checkout changed', result.stderr)

    def test_lead_parallel_limit_and_no_commit_instructions(self):
        path = self.root / 'plan/specs/01-01.md'
        path.write_text(path.read_text().replace('L2', 'L3').replace('Self-review', 'Lead workflow'))
        (self.root / 'plan/specs/01-01.plan.md').write_text('Pending piece: exact signatures and ownership.')
        part = self.root / 'part.md'
        part.write_text('Ownership: Sources/example.swift')
        self.commit()
        for i in range(3):
            self.invoke('lead', '01-01', 'part', str(i), str(part))
        self.invoke('lead', '01-01', 'part', 'fourth', str(part), code=1)
        calls = self.calls('worker-start')
        self.assertEqual(len(calls), 3)
        text = Path(calls[0][calls[0].index('--spec-file') + 1]).read_text()
        self.assertIn('Do not commit or run full acceptance', text)

    def test_invalid_specs_and_arguments_do_not_start(self):
        self.invoke('start', '../bad', code=1)
        self.invoke('start', '01-01', 'unknown', code=1)
        self.invoke('lead', '01-01', 'fix', '3', '/dev/null', code=1)
        self.assertFalse(self.calls('worker-start'))

    def test_watchdog_requires_idle_proof_and_limits_continuations(self):
        self.existing_start()
        self.invoke('wait', '1')
        record_path, = (self.root / '.git/orca-plan-runtime').glob('dispatch-*.json')
        for idle in (False, True, True, True, True):
            record = json.loads(record_path.read_text())
            record['unchangedSince'] = time.time() - 601
            record_path.write_text(json.dumps(record))
            self.state(idle=idle)
            self.invoke('wait', '1')
        self.assertEqual(len(self.calls('send')), 3)
        self.assertFalse(self.calls('worker-stop'))
        self.assertFalse(self.calls('worker-release'))

    def test_watchdog_does_not_nudge_lead_with_active_children(self):
        self.existing_start()
        self.invoke('self-review', '01-01')
        self.invoke('wait', '1')
        record_path = self.root / '.git/orca-plan-runtime/dispatch-ctx_1.json'
        record = json.loads(record_path.read_text())
        record['unchangedSince'] = time.time() - 601
        record_path.write_text(json.dumps(record))
        self.state(idle=True)
        self.invoke('wait', '1')
        self.assertFalse(self.calls('send'))

    def test_merge_rejects_dirty_checkout(self):
        (self.root / 'dirty').write_text('dirty')
        self.invoke('merge', '01-01', 'feature', code=1)
        self.assertEqual(self.command('git', 'log', '-1', '--format=%s'), 'fixture')

    def test_merge_stops_after_failed_acceptance_without_push(self):
        (self.root / 'plan/specs/01-01.review.md').write_text('Reviewed: no blockers.')
        self.commit()
        self.command('git', 'push', 'origin', 'main')
        base = self.command('git', 'rev-parse', 'origin/main')
        self.command('git', 'checkout', '-b', 'feature')
        (self.root / 'feature.txt').write_text('feature')
        (self.root / 'plan/tools/accept.sh').write_text('#!/bin/bash\nexit 37\n')
        (self.root / 'plan/tools/accept.sh').chmod(0o755)
        self.commit()
        self.command('git', 'checkout', 'main')
        self.invoke('merge', '01-01', 'feature', code=1)
        self.assertEqual(self.command('git', 'rev-parse', 'origin/main'), base)
        self.assertNotEqual(self.command('git', 'rev-parse', 'HEAD'), base)

    def test_merge_accepts_once_and_pushes(self):
        (self.root / 'plan/specs/01-01.review.md').write_text('Reviewed: no blockers.')
        self.commit()
        self.command('git', 'push', 'origin', 'main')
        self.command('git', 'checkout', '-b', 'feature')
        (self.root / 'feature.txt').write_text('feature')
        check = self.root / 'plan/tools/accept.sh'
        check.write_text('#!/bin/bash\necho acceptance >> .git/accept-calls\n')
        check.chmod(0o755)
        self.commit()
        self.command('git', 'checkout', 'main')
        self.invoke('merge', '01-01', 'feature')
        self.assertEqual((self.root / '.git/accept-calls').read_text(), 'acceptance\n')
        self.assertEqual(self.command('git', 'rev-parse', 'HEAD'), self.command('git', 'rev-parse', 'origin/main'))


if __name__ == '__main__':
    unittest.main()
