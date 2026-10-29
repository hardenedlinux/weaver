from pathlib import Path
import re,json,hashlib,subprocess
out=Path(__file__).parent
p=Path('docs/50-59-research-program/50-integrated-audit')
a=(p/'50.01-integrated-audit.org').read_text();s=(p/'50.02-research-plan.org').read_text()
assert set(re.findall(r'^\*\* (A\d+) /',a,re.M))=={f'A{i:02}' for i in range(1,13)}
parts=re.split(r'^\*\* (RP\d+) /[^\n]+\n',s,flags=re.M);deps={}
for k,body in zip(parts[1::2],parts[2::2]):
 line=re.search(r'^Depends on: (.+?)\.',body,re.M).group(1)
 deps[k]=re.findall(r'RP\d+',line)
 assert 'Exit evidence' in body,k
assert len(deps)==8
seen=set()
def visit(k,path=()):
 assert k not in path,(k,path)
 for d in deps[k]:visit(d,path+(k,))
 seen.add(k)
for k in deps:visit(k)
for i in range(1,13):assert f'A{i:02}' in s
current=json.loads((out/'source-currentness.json').read_text());assert all(r['headMatches'] and r['workingMatches'] for r in current)
proof=json.loads((out/'clean-proof-receipt.json').read_text())
print('PASS: 12 findings, 8 acyclic research packages; current source matches; clean proof receipt retained')
(out/'plan-check.json').write_text(json.dumps(dict(status='PASS',findings=12,packages=8,dependencies=deps,sourceMatches=len(current)),indent=2)+'\n')
