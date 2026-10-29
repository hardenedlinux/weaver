from pathlib import Path
import json,hashlib,re
ROOT=Path.cwd();OUT=ROOT/'proofs/evidence/llm-bootstrap-invitation'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def norm(x):
 if isinstance(x,list):return [norm(v) for v in x]
 if isinstance(x,dict):return {k:norm(v) for k,v in x.items() if k not in ['id','fromSource']}
 return x
def canon(d):return json.dumps(norm(d),sort_keys=True)
cert=json.loads((OUT/'bundle-certificate.json').read_text());texts=[]
for r in cert['sources']:
 p=ROOT/r['source'];assert digest(p)==r['sourceSha256'];s=re.sub(r'(\bimport [^\n]+?) from "\./[A-Za-z0-9_]+"',r'\1',p.read_text());assert hashlib.sha256(s.encode()).hexdigest()==r['transformedSha256'];texts.append(s)
assert (ROOT/cert['bundle']).read_text()=='\n'.join(texts)
assert digest(ROOT/cert['bundle'])==cert['bundleSha256']
assert (OUT/'quint-core/LlmBootstrapInvitation.qnt').read_bytes()==(ROOT/'proofs/qunit/LlmBootstrapInvitation.qnt').read_bytes()
bundle=json.loads((OUT/'bundle-parsed.json').read_text());modules={m['name']:m for m in bundle['modules']};assert len(modules)==13 and not bundle.get('errors')
parent=json.loads((ROOT/'proofs/evidence/llm-incarnation-issuance/executed-parsed.json').read_text())
for m in parent['modules']:
 expected=[d for d in m['declarations'] if d.get('qualifier')!='run']
 assert sorted(map(canon,expected))==sorted(map(canon,modules[m['name']]['declarations'])),m['name']
raw=json.loads((OUT/'raw-leaf-parsed.json').read_text())['modules'][0]
# Phase three adds lexical depth zero to top-level variable/type declarations.
for d in raw['declarations']:
 if d['kind'] in ['var','typedef']:
  assert next(x for x in modules[raw['name']]['declarations'] if x.get('name')==d['name'])['depth']==0
  d['depth']=0
assert sorted(map(canon,raw['declarations']))==sorted(map(canon,modules[raw['name']]['declarations']))
rows=json.loads((OUT/'bundle-control-shards.json').read_text());tests=[d['name'] for d in raw['declarations'] if d.get('qualifier')=='run'];actualTests=[t for row in rows for t in row['tests']];assert len(actualTests)==len(set(actualTests))==len(tests)==23 and set(actualTests)==set(tests)
for row in rows:assert digest(ROOT/row['source'])==row['sha256']
print('PASS: all 12 ancestor non-run IRs and complete raw current leaf IR match the bundle (IDs/import paths ignored; raw top-level lexical depth zero checked); 23 control spans covered exactly once')
