"""Exercise the real Go-to-Rust queue boundary without invoking any provider."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def replay():
    go = os.environ.get('WEAVER_GO', 'go')
    subprocess.run([go, 'build', '-o', str(ROOT / 'target/weaverctl'), './go/cmd/weaverctl'], cwd=ROOT, check=True)
    subprocess.run(['cargo', 'build', '-p', 'weaver-cli', '--locked', '--offline'], cwd=ROOT, check=True)
    native = str(ROOT / 'target/debug/weaver-cli')
    with tempfile.TemporaryDirectory(prefix='weaver-runtime-') as directory:
        db = str(Path(directory) / 'ledger.db')

        def call(*args, accepted=True):
            result = subprocess.run([native, db, *args], cwd=ROOT, text=True, capture_output=True)
            assert (result.returncode == 0) == accepted, (args, result.stderr)
            return result.stdout

        example = ROOT / 'examples/local-owner'
        call('publish', str(example / 'permit.cedar'), 'new', '1')
        call('register', str(example / 'task.json'))
        proposal = subprocess.check_output([str(ROOT / 'target/weaverctl'), str(example / 'task.json'),
                                            str(example / 'request.json'), '0', '1'], text=True)
        path = Path(directory) / 'proposal.json'
        path.write_text(proposal)
        first = json.loads(call('enqueue', str(path)))
        repeated = json.loads(call('enqueue', str(path)))
        assert first == repeated and first['reserved'] == 25 and first['outcome'] == 'queued'
        changed = json.loads(proposal)
        changed['ceiling'] = 26
        path.write_text(json.dumps(changed))
        call('enqueue', str(path), accepted=False)
        empty_policy = Path(directory) / 'deny.cedar'
        empty_policy.write_text('')
        call('publish', str(empty_policy), '0', '2')
        call('execute', 'demo-family', 'infer', accepted=False)
        assert json.loads(call('lookup', 'demo-family', 'infer')) == first
        return dict(status='PASS', realGoProposal=True, rustQueue=True, sameKeyReplay=True,
                    changedWireRejected=True, publicationBlocksOldQueue=True,
                    providerCalls=0, reservationRetained=True)


if __name__ == '__main__':
    print(json.dumps(replay(), indent=2))
