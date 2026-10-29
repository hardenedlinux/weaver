"""Seal the scoped native delivery without rewriting any older evidence."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

root = Path.cwd()
out = Path(__file__).parent
assert not (out / 'SHA256SUMS').exists(), 'A sealed generation is immutable'
tests = (out / 'rust-tests.log').read_text()
assert sum(map(int, re.findall(r'test result: ok\. (\d+) passed', tests))) == 20
assert tests.count('test enforce_asp_rust_gate ... ok') == 5
assert '13 passing' in (out / 'quint-tests.log').read_text()
assert 'No violation found' in (out / 'quint-safety.log').read_text()
lean = (out / 'lean.log').read_text()
assert 'sorryAx' not in lean and lean.count("'Weaver.RuntimeAdmission.") == 4
assert (out / 'full-check.log').read_text().count('PASS ') == 13
assert 'FAIL' not in (out / 'full-check.log').read_text()
assert 'no errors' in (out / 'sysml-ports.log').read_text()
assert 'Finished' in (out / 'rust-clippy.log').read_text()
trace = json.loads((out / 'trace.log').read_text())
assert trace['aspRustDevelopmentOnly'] and trace['explicitRuntimeLayers']
historical = json.loads((out / 'historical-seals.json').read_text())
assert len(historical['manifests']) == 52 and len(historical['drift']) == 1
assert historical['drift'][0]['target'] == 'docs/architecture/01-reference-comparison.org'
assert 'PASS:' in (out / 'document-inventory-final.log').read_text()
assert 'exported 4 Org documents' in (out / 'org-export.log').read_text()

bindings = {}
files = set()
for directory in ['crates', 'control', 'cmd', 'models', 'scripts', 'examples/local-owner']:
    files.update(p for p in Path(directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
files.update(Path(p) for p in ['Cargo.toml', 'Cargo.lock', 'go.mod', 'clippy.toml', 'rustfmt.toml', '.gitignore',
                            'proofs/lean/RuntimeAdmission.lean', 'proofs/qunit/RuntimeAdmission.qnt'])
for path in sorted(files):
    bindings[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
(out / 'native-source-bindings.json').write_text(json.dumps(bindings, indent=2) + '\n')

for repository in json.loads((out / 'source-identity.json').read_text()):
    source = Path(repository['repository'])
    assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == repository['head']
    for row in repository['files']:
        assert hashlib.sha256((source / row['path']).read_bytes()).hexdigest() == row['sha256']

receipt = dict(status='INITIAL_LOCAL_OWNER_RUNTIME_QUALIFIED', date='2026-10-29',
    rustModules=5, nativeTests=20, aspDenyGates=5, rustPbtCases=64,
    quintControls=13, quintSampledTraces=1000, quintTransitionsPerTrace=50,
    leanDeclarations=4, sysmlRequirements=7, sysmlTypedPortsValidated=True,
    realLoopbackTls=True, crossLanguageQueueReplay=True, currentClippyAndTrace=True,
    developmentOnlyAspRust=trace['aspRustRevision'], historicalSourceDrift=historical['drift'],
    originalTaskAndCostBound=True, unknownBudgetNeverReleased=True,
    historicalManifestsRewritten=False, existingDependencyPinsChanged=False,
    runtimeImplemented=True, productionGatewayComplete=False,
    upstreamLeanWorkerIntegrated=False, schemeNativePublisherIntegrated=False,
    authorityBoundary='Trusted local management; one non-rollback deciding SQLite store',
    transportBoundary='Bounded non-streaming HTTPS; no redirects, retries or response-body disclosure',
    performanceClaim=False, providerExactlyOnceClaim=False)
(out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
files.update(p for p in out.rglob('*') if p.is_file() and p.name != 'SHA256SUMS' and '__pycache__' not in p.parts)
files.update(p for p in Path('docs/50-59-research-program/57-runtime-implementation').glob('*') if p.is_file())
files.update(Path(p) for p in ['docs/architecture/diagrams/lib/theme.d2', 'docs/architecture/diagrams/assets/go.svg', 'docs/architecture/diagrams/assets/rust.svg'])
(out / 'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + str(p) + '\n' for p in sorted(files)))
print('SEALED', len(files), 'targets; native profile qualified; one unowned historical source drift retained')
