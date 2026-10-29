from pathlib import Path
import hashlib,json,re
ROOT=Path.cwd();OUT=ROOT/'proofs/evidence/llm-beneficiary-registration';PRIOR=ROOT/'proofs/evidence/llm-bootstrap-invitation'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def norm(x):
 if isinstance(x,list):return [norm(v) for v in x]
 if isinstance(x,dict):return {k:norm(v) for k,v in x.items() if k not in ['id','fromSource']}
 return x
def canon(d):return json.dumps(norm(d),sort_keys=True)
cert=json.loads((OUT/'bundle-certificate.json').read_text());assert sha(ROOT/cert['parent'])==cert['parentSha256'];assert sha(ROOT/cert['raw'])==cert['rawSha256'];assert sha(ROOT/cert['bundle'])==cert['bundleSha256']
new=re.sub(r'(\bimport [^\n]+?) from "\./[A-Za-z0-9_]+"',r'\1',(ROOT/cert['raw']).read_text())
assert (ROOT/cert['bundle']).read_text()==(ROOT/cert['parent']).read_text()+'\n'+new
parsed=json.loads((OUT/'bundle-parsed.json').read_text());assert not parsed.get('errors');modules={m['name']:m for m in parsed['modules']};assert len(modules)==14
parent=json.loads((PRIOR/'bundle-parsed.json').read_text())
for m in parent['modules']:
 expected=[d for d in m['declarations'] if d.get('qualifier')!='run']
 assert sorted(map(canon,expected))==sorted(map(canon,modules[m['name']]['declarations'])),m['name']
raw=json.loads((OUT/'raw-leaf-parsed.json').read_text())['modules'][0]
for d in raw['declarations']:
 if d['kind'] in ['var','typedef']:
  assert next(x for x in modules[raw['name']]['declarations'] if x.get('name')==d['name'])['depth']==0
  d['depth']=0
assert sorted(map(canon,raw['declarations']))==sorted(map(canon,modules[raw['name']]['declarations']))
groups=json.loads((OUT/'api-groups.json').read_text());tests=[d['name'] for d in raw['declarations'] if d.get('qualifier')=='run'];actual=[t for row in groups for t in row]
assert len(actual)==len(set(actual))==len(tests)==32 and set(actual)==set(tests)
print('PASS: thirteen ancestor transition IRs and full raw leaf IR retained; all 32 controls covered exactly once; types/effects and invariant unchanged')
