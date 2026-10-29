#!/usr/bin/env python3
"""Run the floor-intent-decision proof/model checks without changing dependencies."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'dev/proofs/evidence/floor-intent-decision'
MODULES = ['LogicalMessageAuthority', 'SharedMessageBudget', 'FiniteDomainMigration',
           'AnchoredRecoveryAndEgress', 'ComposedGatewayLifecycle', 'FiniteStreamManifest',
           'DriverCompletionRecovery', 'WriterSettlementClosure', 'SettlementAnchorRecovery',
           'GateConsumptionPersistence', 'AnchorBrokerCommit', 'AnchorReconfiguration',
           'QuorumDurablePromises']

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    commands = []
    proof = Path(tempfile.mkdtemp(prefix='weaver-floor-intent-decision-proof-'))
    env = dict(os.environ, LEAN_PATH=str(proof))

    def run(label, args, watchdog=20, command_env=None):
        started = time.monotonic()
        with (OUT / (label + '.log')).open('w') as log:
            try:
                result = subprocess.run(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                        timeout=watchdog, env=command_env)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code = 124
        commands.append(dict(label=label, args=args, watchdogSeconds=watchdog,
                             seconds=round(time.monotonic() - started, 3), exit=code))
        (OUT / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        print(label, code, flush=True)
        if code:
            raise SystemExit(code)

    for module in MODULES + ['ProtectedSignerRelease', 'KeyBoundaryQueue', 'DeviceIsolationRecovery', 'FloorIntentDecision']:
        source = ('dev/specs/lean/' if module in MODULES else 'dev/proofs/lean/') + module + '.lean'
        run(module, ['elan', 'run', 'leanprover/lean4:v4.34.1', 'lean', '-o',
                     str(proof / (module + '.olean')), source], command_env=env)
    proof_output = (OUT / 'FloorIntentDecision.log').read_text()
    assert 'sorryAx' not in proof_output and 'error:' not in proof_output, 'Unclosed Lean proof'
    assert sum(line.startswith("'Weaver.FloorIntentDecision.") for line in proof_output.splitlines()) == 19
    source = 'dev/proofs/quint/FloorIntentDecision.qnt'
    run('typecheck', ['quint', 'typecheck', source])
    run('tests', ['quint', 'test', source, '--backend', 'typescript', '--max-samples', '1', '--match', 'Test$'], 55)
    (OUT / 'itf').mkdir(exist_ok=True)
    run('counterexamples', ['quint', 'test', source, '--backend', 'typescript', '--max-samples', '1',
                           '--match', '(timeoutUnlock|lateCommitAfterFence|rollbackDecisionPrefix|negativeResolutionUnlock|oldWorkerReceiptRelabel)CounterexampleTest$', '--out-itf',
                           'dev/proofs/evidence/floor-intent-decision/itf/{test}-{seq}.itf.json'], 55)
    for initializer in ['init', 'boot', 'pending', 'committedPending', 'fencedPending', 'signed']:
        run(initializer, ['quint', 'run', source, '--backend', 'typescript', '--init', initializer,
                          '--step', 'step', '--invariant', 'safety', '--max-samples', '10',
                          '--max-steps', '25', '--seed', '113', '--verbosity', '1'], 30)
    run('device-isolation-regression', ['quint', 'test', 'dev/proofs/quint/DeviceIsolationRecovery.qnt', '--backend', 'typescript', '--max-samples', '1', '--match', 'Test$'], 55)
    run('protected-signer-regression', ['quint', 'test', 'dev/proofs/quint/ProtectedSignerRelease.qnt', '--backend', 'typescript', '--max-samples', '1'], 55)
    run('inherited-account-replay', ['quint', 'test', 'dev/specs/quint/AnchorReconfiguration.qnt',
                                   '--backend', 'typescript', '--max-samples', '1', '--match',
                                   '^disjointReplacementReplaysActualApplicationCounterexampleTest$'], 55)

if __name__ == '__main__':
    main()
