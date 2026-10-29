from pathlib import Path
import hashlib,json
root=Path.cwd();out=root/'proofs/evidence/llm-custody-publication'
records=json.loads((out/'closure-certificate.json').read_text())
original={m['name']:m for m in json.loads((out/'original-parsed.json').read_text())['modules']}
core={m['name']:m for m in json.loads((out/'closure-parsed.json').read_text())['modules']}
keep={'LlmCustodyPublication','LlmSourceCustody'}
def normalized(x):
 if isinstance(x,list):return [normalized(v) for v in x]
 if isinstance(x,dict):return {k:normalized(v) for k,v in x.items() if k!='id'}
 return x
def canonical(d):return json.dumps(normalized(d),sort_keys=True)
assert len(records)==10 and set(original)==set(core)=={r['module'] for r in records}
for r in records:
 assert hashlib.sha256((root/r['source']).read_bytes()).hexdigest()==r['sourceSha256'],r['module']
 assert hashlib.sha256((root/r['corePath']).read_bytes()).hexdigest()==r['coreSha256'],r['module']
 expected=[d for d in original[r['module']]['declarations'] if d.get('qualifier')!='run' or r['module'] in keep]
 assert sorted(map(canonical,expected))==sorted(map(canonical,core[r['module']]['declarations'])),r['module']
 if r['module'] in keep:assert r['sourceSha256']==r['coreSha256'],r['module']
 assert r['retainedDeclarationIRIdentical'] and r['onlyOmittedRunSpansBlanked']
assert sum(r['removedRuns'] for r in records)==308 and sum(r['retainedRuns'] for r in records)==48
print('PASS: ten current source/core hashes and normalized retained declaration IRs rechecked; current/parent models byte-identical; 25+23 controls retained')
