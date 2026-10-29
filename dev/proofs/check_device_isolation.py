#!/usr/bin/env python3
"""Run the device-isolation proof/model checks without changing dependencies."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'dev/proofs/evidence/device-isolation'
MODULES = ['LogicalMessageAuthority', 'SharedMessageBudget', 'FiniteDomainMigration',
           'AnchoredRecoveryAndEgress', 'ComposedGatewayLifecycle', 'FiniteStreamManifest',
           'DriverCompletionRecovery', 'WriterSettlementClosure', 'SettlementAnchorRecovery',
           'GateConsumptionPersistence', 'AnchorBrokerCommit', 'AnchorReconfiguration',
           'QuorumDurablePromises']

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    commands = []
    proof = Path(tempfile.mkdtemp(prefix='weaver-device-isolation-proof-'))
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

    for module in MODULES + ['ProtectedSignerRelease', 'KeyBoundaryQueue', 'DeviceIsolationRecovery']:
        source = ('dev/specs/lean/' if module in MODULES else 'dev/proofs/lean/') + module + '.lean'
        run(module, ['elan', 'run', 'leanprover/lean4:v4.34.1', 'lean', '-o',
                     str(proof / (module + '.olean')), source], command_env=env)
    source = 'dev/proofs/quint/DeviceIsolationRecovery.qnt'
    run('typecheck', ['quint', 'typecheck', source])
    run('tests', ['quint', 'test', source, '--backend', 'typescript', '--max-samples', '1', '--match', 'Test$'], 55)
    (OUT / 'itf').mkdir(exist_ok=True)
    run('counterexamples', ['quint', 'test', source, '--backend', 'typescript', '--max-samples', '1',
                           '--match', '(resetReceiptReplay|omittedOldFDIsolation|retainedDMABufferLeaksOnReset|lateCallbackRelabelsNewJob|resettableDeviceCounterRestoresFloor|resetForgetsAcceptedFloorIntent|floorScalarWithoutCommitPrefix)CounterexampleTest$', '--out-itf',
                           'dev/proofs/evidence/device-isolation/itf/{test}-{seq}.itf.json'], 55)
    for initializer in ['init', 'boot', 'running', 'computed', 'barrierPending', 'freshPending']:
        run(initializer, ['quint', 'run', source, '--backend', 'typescript', '--init', initializer,
                          '--step', 'step', '--invariant', 'safety', '--max-samples', '10',
                          '--max-steps', '25', '--seed', '109', '--verbosity', '1'], 30)
    run('protected-signer-regression', ['quint', 'test', 'dev/proofs/quint/ProtectedSignerRelease.qnt', '--backend', 'typescript', '--max-samples', '1'], 55)
    run('inherited-account-replay', ['quint', 'test', 'dev/specs/quint/AnchorReconfiguration.qnt',
                                   '--backend', 'typescript', '--max-samples', '1', '--match',
                                   '^disjointReplacementReplaysActualApplicationCounterexampleTest$'], 55)

if __name__ == '__main__':
    main()
