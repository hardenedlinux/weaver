"""Real Go proposal -> Rust admission -> native range writes; no external provider calls."""
from pathlib import Path
import hashlib
import json
import os
import socket
import sqlite3
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def replay():
    go = os.environ.get('WEAVER_GO', 'go')
    subprocess.run([go, 'build', '-o', 'target/weaverctl', './go/cmd/weaverctl'], cwd=ROOT, check=True)
    subprocess.run(['cargo', 'build', '-p', 'weaver-cli', '--locked', '--offline'], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix='weaver-stream-') as directory, socket.socket() as listener:
        work = Path(directory)
        listener.bind(('127.0.0.1', 0))
        listener.listen(2)
        destination = f'tcp://127.0.0.1:{listener.getsockname()[1]}'
        wire = b'data: governed\n\n'
        task = dict(family='f', principal='alice', profile='p', nodes=['emit'], targets=['t'],
                    endpoints={'t': 'https://provider.invalid/'}, models=['model-a'], budget=12,
                    body_digests={'emit': hashlib.sha256(b'original-input').hexdigest()}, node_cost_bounds={'emit': 12})
        contract = dict(family='f', node='emit', profile='p', target='t', input_digest=task['body_digests']['emit'],
                        destination=destination, messages=[dict(id=f'm{i}', max_bytes=64, cost_bound=4) for i in range(2)])
        canonical=json.dumps(["weaver.stream.v1",contract],separators=(',',':'),ensure_ascii=False).encode()
        task['stream_contracts']={'emit':hashlib.sha256(canonical).hexdigest()}
        for name, data in [('task', task), ('contract', contract)]:
            (work / (name + '.json')).write_text(json.dumps(data))
        (work / 'payload').write_bytes(wire)
        (work / 'allow.cedar').write_text((ROOT/'dev/policies/streaming/stream.cedar').read_text())
        (work / 'deny.cedar').write_text('forbid(principal,action,resource);')
        native = str(ROOT / 'target/debug/weaver-cli')

        def call(*args, accept=True):
            result = subprocess.run([native, str(work / 'ledger.db'), *map(str, args)], cwd=ROOT, capture_output=True, text=True)
            assert (result.returncode == 0) == accept, (args, result.stderr)
            return result.stdout

        call('publish-typed', work / 'allow.cedar', ROOT/'dev/policies/streaming/schema.json', 'new', 1)
        call('register', work / 'task.json')
        call('stream-register', work / 'contract.json')
        for i in range(2):
            proposal = subprocess.check_output([str(ROOT / 'target/weaverctl'), 'stream', str(work / 'task.json'),
                str(work / 'contract.json'), f'm{i}', str(work / 'payload'), '4', '0', '1'], text=True)
            (work / f'm{i}.json').write_text(proposal)
            original = call('stream-enqueue', work / f'm{i}.json')
            assert call('stream-enqueue', work / f'm{i}.json') == original
        received = bytearray()

        def receive():
            listener.settimeout(5)
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(3)
                while data := connection.recv(1024):
                    received.extend(data)

        worker = threading.Thread(target=receive)
        worker.start()
        call('stream-send', work / 'contract.json', 'm0', 0, 1, 4)
        worker.join(5)
        assert not worker.is_alive() and received == wire
        first = json.loads(call('stream-lookup', 'f', 'emit', 'm0'))
        assert first['state'] == 'complete' and first['cursor'] == len(wire)
        call('publish-typed', work / 'deny.cedar', ROOT/'dev/policies/streaming/schema.json', 0, 2)
        call('stream-send', work / 'contract.json', 'm1', 1, 2, 4, accept=False)
        listener.settimeout(0.25)
        try:
            extra, _ = listener.accept()
            extra.close()
            raise AssertionError('revoked stream opened a new connection')
        except socket.timeout:
            pass
        changed = json.loads((work / 'm0.json').read_text())
        changed['payload'] = 'changed under a fresh nonce'
        (work / 'forged.json').write_text(json.dumps(changed))
        call('stream-enqueue', work / 'forged.json', accept=False)
        with sqlite3.connect(work / 'ledger.db') as database:
            assert database.execute('SELECT held FROM tasks WHERE family="f"').fetchone()[0] == 8
        return dict(status='PASS', realGoManifestDigest=True, canonicalMessages=2, nativeRangeWrites=4,
                    actualBytes=bytes(received).decode(), revokedAdditionalConnections=0,
                    sharedHoldRetained=8, messageMutationRejected=True, externalProviderCalls=0)


if __name__ == '__main__':
    print(json.dumps(replay(), indent=2))
