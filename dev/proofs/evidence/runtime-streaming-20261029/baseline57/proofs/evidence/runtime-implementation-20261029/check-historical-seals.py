from pathlib import Path
import hashlib
import json

out = Path(__file__).parent
cache, seals, drift = {}, [], []
for manifest in sorted([*Path('specs/evidence').glob('*/SHA256SUMS'), *Path('proofs/evidence').glob('*/SHA256SUMS')]):
    if manifest.parent == out:
        continue
    count = 0
    for line in manifest.read_text().splitlines():
        expected, name = line.split('  ', 1)
        if name not in cache:
            cache[name] = hashlib.sha256(Path(name).read_bytes()).hexdigest() if Path(name).is_file() else None
        if cache[name] != expected:
            drift.append(dict(manifest=str(manifest),target=name,expected=expected,actual=cache[name]))
        count += 1
    seals.append(dict(path=str(manifest), targets=count, sha256=hashlib.sha256(manifest.read_bytes()).hexdigest()))
assert len(seals) == 52, len(seals)
result = dict(status='PASS' if not drift else 'HISTORICAL_SOURCE_DRIFT', manifests=seals, uniqueTargets=len(cache), drift=drift)
(out / 'historical-seals.json').write_text(json.dumps(result, indent=2) + '\n')
print(result['status'], len(seals), 'historical seals;', len(cache), 'unique targets;', len(drift), 'target differences')
