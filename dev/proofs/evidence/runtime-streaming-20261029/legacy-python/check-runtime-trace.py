"""Check named requirement evidence and native development/runtime dependency separation."""
import json
from pathlib import Path
import re
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def check():
    trace = json.loads((ROOT / "dev/models/runtime-trace.json").read_text())
    model = '\n'.join(p.read_text() for p in (ROOT/'dev/models/sysml').glob('*.sysml'))
    declared = set(re.findall(r'requirement def (\w+)', model))
    assert declared == {r['id'] for r in trace}, 'Unmapped or stale SysML requirements'
    for requirement in trace:
        assert f"requirement def {requirement['id']}" in model, requirement['id']
        for witness in requirement['witnesses']:
            text = (ROOT / witness['file']).read_text()
            assert re.search(witness['pattern'], text), witness
    metadata = json.loads(subprocess.check_output(
        ['cargo', 'metadata', '--locked', '--offline', '--format-version', '1'], cwd=ROOT))
    packages = {p['id']: p for p in metadata['packages']}
    nodes = {n['id']: n for n in metadata['resolve']['nodes']}
    native = metadata['workspace_members']
    layers = {
        'weaver-contracts': set(),
        'weaver-policy': {'weaver-contracts'},
        'weaver-ledger': {'weaver-contracts', 'weaver-policy'},
        'weaver-execution': {'weaver-contracts', 'weaver-ledger'},
        'weaver-cli': {'weaver-contracts', 'weaver-ledger', 'weaver-execution', 'weaver-policy'},
        'weaver-server': {'weaver-contracts','weaver-ledger','weaver-execution'},
    }
    for root in native:
        package = packages[root]
        member=tomllib.loads(Path(package['manifest_path']).read_text())
        for section in ['dependencies','dev-dependencies','build-dependencies']:
            for name,spec in member.get(section,{}).items():
                assert isinstance(spec,dict) and spec.get('workspace') is True,(package['name'],section,name)
        direct = {d['name'] for d in package['dependencies']
                  if d['kind'] is None and d['name'].startswith('weaver-')}
        assert direct == layers[package['name']], (package['name'], direct)
        asp = [d for d in package['dependencies'] if d['name'] == 'asp-rust']
        assert len(asp) == 1 and asp[0]['kind'] == 'dev', package['name']
        reached, todo = set(), [root]
        while todo:
            node = todo.pop()
            if node in reached:
                continue
            reached.add(node)
            assert packages[node]['name'] != 'asp-rust', (package['name'], 'runtime ASP edge')
            for edge in nodes[node]['deps']:
                if any(k['kind'] is None for k in edge['dep_kinds']):
                    todo.append(edge['pkg'])
        lib = Path(package['manifest_path']).parent / 'src/lib.rs'
        source = lib.read_text()
        assert '#[cfg(test)]' in source and 'mode = deny' in source
        assert 'asp_rust_cargo_test_gate!' in source
        assert 'advice = allow' not in source and 'with_disabled' not in source
    manifest = tomllib.loads((ROOT / 'Cargo.toml').read_text())
    asp_pin = manifest['workspace']['dependencies']['asp-rust']
    assert re.fullmatch('[0-9a-f]{40}', asp_pin['rev'])
    return dict(status='PASS', requirements=len(trace), nativeModules=len(native),
                aspRustDevelopmentOnly=True, denyModeEveryCrate=True,
                explicitRuntimeLayers=True,
                aspRustRevision=asp_pin['rev'],
                scope='Named trace references and dependency graph; not behavioral refinement proof')


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
