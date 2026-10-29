from pathlib import Path
import json,hashlib
root=Path.cwd();out=root/'proofs/evidence/llm-incarnation-issuance';c=json.loads((out/'closure-certificate.json').read_text())
def norm(x):
 if isinstance(x,list):return [norm(v) for v in x]
 if isinstance(x,dict):return {k:norm(v) for k,v in x.items() if k!='id'}
 return x
def canonical(d):return json.dumps(norm(d),sort_keys=True)
parents={m['name']:m for m in json.loads((out/'parent-parsed.json').read_text())['modules']}
executed={m['name']:m for m in json.loads((out/'executed-parsed.json').read_text())['modules']}
assert len(c['ancestors'])==11 and set(executed)==set(parents)|{'LlmIncarnationIssuance'}
for row in c['ancestors']:
 for path,h in [(row['rawSource'],row['rawSha256']),(row['parentCore'],row['parentCoreSha256']),(row['executed'],row['executedSha256'])]:assert hashlib.sha256((root/path).read_bytes()).hexdigest()==h,path
 a=[d for d in parents[row['module']]['declarations'] if d.get('qualifier')!='run'];b=executed[row['module']]['declarations']
 assert sorted(map(canonical,a))==sorted(map(canonical,b)),row['module']
assert (root/c['newSource']).read_bytes()==(root/c['newExecuted']).read_bytes()
assert hashlib.sha256((root/c['newSource']).read_bytes()).hexdigest()==c['newSha256']
assert len(c['tests'])==31 and c['totalHistoricalRunOmissions']==383
prior=root/'proofs/evidence/llm-caller-custody'
for row in json.loads((prior/'closure-certificate.json').read_text()):
 assert hashlib.sha256((root/row['source']).read_bytes()).hexdigest()==row['sourceSha256']
 assert hashlib.sha256((root/row['corePath']).read_bytes()).hexdigest()==row['coreSha256']
assert (prior/'quint-core/LlmCallerCustody.qnt').read_bytes()==(root/'proofs/qunit/LlmCallerCustody.qnt').read_bytes()
simulation={m['name']:m for m in json.loads((out/'simulation-parsed.json').read_text())['modules']}
assert set(simulation)==set(executed)
for name,module in executed.items():
 expected=[d for d in module['declarations'] if d.get('qualifier')!='run']
 assert sorted(map(canonical,expected))==sorted(map(canonical,simulation[name]['declarations'])),('simulation IR',name)
for path,h in c['simulationFiles'].items():assert hashlib.sha256((root/path).read_bytes()).hexdigest()==h,path
assert c['simulationOmittedCurrentRuns']==31
print('PASS: test and simulation closures retain identical non-run IR; 12 modules; exact current/ancestor hashes; 31 current controls execute separately from 27 predecessor controls')
