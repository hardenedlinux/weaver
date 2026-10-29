#!/usr/bin/env python3
"""Run the fenced-intent-continuation proof/model checks without changing dependencies."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'proofs/evidence/fenced-intent-continuation'
MODULES = ['LogicalMessageAuthority', 'SharedMessageBudget', 'FiniteDomainMigration',
           'AnchoredRecoveryAndEgress', 'ComposedGatewayLifecycle', 'FiniteStreamManifest',
           'DriverCompletionRecovery', 'WriterSettlementClosure', 'SettlementAnchorRecovery',
           'GateConsumptionPersistence', 'AnchorBrokerCommit', 'AnchorReconfiguration',
           'QuorumDurablePromises']

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    commands = []
    proof = Path(tempfile.mkdtemp(prefix='weaver-fenced-intent-continuation-proof-'))
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

    for module in MODULES + ['ProtectedSignerRelease', 'KeyBoundaryQueue', 'DeviceIsolationRecovery', 'FloorIntentDecision', 'FencedIntentContinuation']:
        source = ('specs/lean/' if module in MODULES else 'proofs/lean/') + module + '.lean'
        run(module, ['elan', 'run', 'leanprover/lean4:v4.34.1', 'lean', '-o',
                     str(proof / (module + '.olean')), source], command_env=env)
    proof_output = (OUT / 'FencedIntentContinuation.log').read_text()
    assert 'sorryAx' not in proof_output and 'error:' not in proof_output, 'Unclosed Lean proof'
    assert sum(line.startswith("'Weaver.FencedIntentContinuation.") for line in proof_output.splitlines()) == 24
    source = 'proofs/qunit/FencedIntentContinuation.qnt'
    run('typecheck', ['quint', 'typecheck', source])
    run('tests', ['quint', 'test', source, '--backend', 'typescript', '--max-samples', '1', '--match', 'Test$'], 55)
    (OUT / 'itf').mkdir(exist_ok=True)
    run('counterexamples', ['quint', 'test', source, '--backend', 'typescript', '--max-samples', '1',
                           '--match', '(recutUnlock|newRootLaundering|duplicateRootCommit|lostFenceLineage|rollbackCommittedContinuation)CounterexampleTest$', '--out-itf',
                           'proofs/evidence/fenced-intent-continuation/itf/{test}-{seq}.itf.json'], 55)
    for initializer in ['recovering', 'admittedLink', 'linked', 'prepared', 'resumedPending', 'resumeReady']:
        run(initializer, ['quint', 'run', source, '--backend', 'typescript', '--init', initializer,
                          '--step', 'step', '--invariant', 'safety', '--max-samples', '10',
                          '--max-steps', '25', '--seed', '127', '--verbosity', '1'], 30)
    run('floor-decision-regression', ['quint', 'test', 'proofs/qunit/FloorIntentDecision.qnt', '--backend', 'typescript', '--max-samples', '1', '--match', 'Test$'], 55)
    run('device-isolation-regression', ['quint', 'test', 'proofs/qunit/DeviceIsolationRecovery.qnt', '--backend', 'typescript', '--max-samples', '1', '--match', 'Test$'], 55)
    run('protected-signer-regression', ['quint', 'test', 'proofs/qunit/ProtectedSignerRelease.qnt', '--backend', 'typescript', '--max-samples', '1'], 55)
    run('inherited-account-replay', ['quint', 'test', 'specs/quint/AnchorReconfiguration.qnt',
                                   '--backend', 'typescript', '--max-samples', '1', '--match',
                                   '^disjointReplacementReplaysActualApplicationCounterexampleTest$'], 55)

if __name__ == '__main__':
    main()
