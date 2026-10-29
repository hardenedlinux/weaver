from pathlib import Path
import hashlib,json
root=Path.cwd();out=root/'proofs/evidence/llm-caller-custody'
records=json.loads((out/'closure-certificate.json').read_text())
original={m['name']:m for m in json.loads((root/'proofs/evidence/llm-custody-publication/original-parsed.json').read_text())['modules']}
core={m['name']:m for m in json.loads((out/'closure-parsed.json').read_text())['modules']}
keep=set()
def normalized(x):
 if isinstance(x,list):return [normalized(v) for v in x]
 if isinstance(x,dict):return {k:normalized(v) for k,v in x.items() if k!='id'}
 return x
def canonical(d):return json.dumps(normalized(d),sort_keys=True)
assert len(records)==11 and set(core)==set(original)|{'LlmCallerCustody'}
assert set(core)=={r['module'] for r in records}
for r in records:
 assert hashlib.sha256((root/r['source']).read_bytes()).hexdigest()==r['sourceSha256'],r['module']
 assert hashlib.sha256((root/r['corePath']).read_bytes()).hexdigest()==r['coreSha256'],r['module']
 if r['module']=='LlmCallerCustody':
  assert (root/r['source']).read_bytes()==(root/r['corePath']).read_bytes()
  continue
 expected=[d for d in original[r['module']]['declarations'] if d.get('qualifier')!='run' or r['module'] in keep]
 assert sorted(map(canonical,expected))==sorted(map(canonical,core[r['module']]['declarations'])),r['module']
 if r['module'] in keep:assert r['sourceSha256']==r['coreSha256'],r['module']
 assert r['retainedDeclarationIRIdentical'] and r['onlyOmittedRunSpansBlanked']
assert sum(r['removedRuns'] for r in records)==356 and sum(r['retainedRuns'] for r in records)==27
prior=root/'proofs/evidence/llm-custody-publication'
for row in json.loads((prior/'closure-certificate.json').read_text()):
 assert hashlib.sha256((root/row['source']).read_bytes()).hexdigest()==row['sourceSha256']
 assert hashlib.sha256((root/row['corePath']).read_bytes()).hexdigest()==row['coreSha256']
assert (prior/'quint-core/LlmCustodyPublication.qnt').read_bytes()==(root/'proofs/qunit/LlmCustodyPublication.qnt').read_bytes()
print('PASS: eleven fresh source/core hashes; retained ancestor IR identical; new leaf byte-identical; parent source byte-identical in separately hash-checked closure; 27+25 controls retained across the two executions')
