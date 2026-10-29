#!/usr/bin/env python3
"""Preserve transition IR while omitting unrelated transitive run declarations."""
from pathlib import Path
import hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'proofs/evidence/llm-custody-publication'
KEEP={'LlmCustodyPublication','LlmSourceCustody'}
def normalized(x):
 if isinstance(x,list):return [normalized(v) for v in x]
 if isinstance(x,dict):return {k:normalized(v) for k,v in x.items() if k!='id'}
 return x
def names(x):
 if isinstance(x,list):return [n for v in x for n in names(v)]
 if isinstance(x,dict):return ([x['name']] if x.get('kind')=='name' else [])+[n for k,v in x.items() if k!='id' for n in names(v)]
 return []
def main():
 OUT.mkdir(parents=True,exist_ok=True)
 source='proofs/qunit/LlmCustodyPublication.qnt'
 subprocess.run(['quint','parse',source,'--out',str(OUT/'original-parsed.json'),'--source-map',str(OUT/'source-map.json')],cwd=ROOT,check=True,timeout=20)
 original=json.loads((OUT/'original-parsed.json').read_text())
 assert not original.get('errors')
 removed=set();expect=[];records=[];sources=json.loads((OUT/'source-map.json').read_text());core=OUT/'quint-core';core.mkdir(exist_ok=True)
 for m in original['modules']:
  target=ROOT/'proofs/qunit'/f"{m['name']}.qnt";assert target.is_file()
  omitted=[d for d in m['declarations'] if d.get('qualifier')=='run' and m['name'] not in KEEP]
  removed.update(d['name'] for d in omitted)
  kept=[d for d in m['declarations'] if d not in omitted]
  expect.append(dict(m,declarations=kept))
  text=target.read_text();assert text.isascii()
  spans=[]
  for d in omitted:
   loc=sources['map'][str(d['id'])];expr=sources['map'][str(d['expr']['id'])]
   assert loc[0]==expr[0] and Path(sources['sourceIndex'][str(loc[0])]).resolve()==target.resolve()
   begin=text.rfind('\n',0,loc[1]['index'])+1;end=expr[2]['index']+1
   assert re.fullmatch(r'\s*run\s+',text[begin:loc[1]['index']])
   spans.append((begin,end))
  for begin,end in sorted(spans,reverse=True):text=text[:begin]+''.join('\n' if c=='\n' else ' ' for c in text[begin:end])+text[end:]
  (core/(m['name']+'.qnt')).write_text(text)
  records.append(dict(module=m['name'],source=str(target.relative_to(ROOT)),sourceSha256=hashlib.sha256(target.read_bytes()).hexdigest(),removedRuns=len(omitted),retainedRuns=sum(d.get('qualifier')=='run' for d in kept)))
 for m in expect:
  for d in m['declarations']:
   assert not any(n.split('::')[-1] in removed for n in names(d)),('retained declaration references omitted test',m['name'],d.get('name'))
 (OUT/'expected-closure.json').write_text(json.dumps(dict(modules=expect),indent=2)+'\n')
 subprocess.run(['quint','parse',str(core/'LlmCustodyPublication.qnt'),'--out',str(OUT/'closure-parsed.json')],cwd=ROOT,check=True,timeout=20)
 actual=json.loads((OUT/'closure-parsed.json').read_text());assert not actual.get('errors')
 actualModules={m['name']:m for m in actual['modules']}
 assert set(actualModules)=={m['name'] for m in expect}
 for m,r in zip(expect,records):
  key=lambda d:json.dumps(normalized(d),sort_keys=True)
  assert sorted(map(key,m['declarations']))==sorted(map(key,actualModules[m['name']]['declarations'])),('IR mismatch',m['name'])
  r.update(corePath=str((core/(m['name']+'.qnt')).relative_to(ROOT)),coreSha256=hashlib.sha256((core/(m['name']+'.qnt')).read_bytes()).hexdigest(),retainedDeclarationIRIdentical=True,onlyOmittedRunSpansBlanked=True)
 assert sum(r['retainedRuns'] for r in records)==48
 assert all(hashlib.sha256((ROOT/r['source']).read_bytes()).hexdigest()==r['sourceSha256'] for r in records)
 (OUT/'closure-certificate.json').write_text(json.dumps(records,indent=2)+'\n')
 print(f'PASS: {len(records)} source modules; retained declaration IR identical; 25 new and 23 parent controls retained; {sum(r["removedRuns"] for r in records)} transitive run declarations omitted')
if __name__=='__main__':main()
