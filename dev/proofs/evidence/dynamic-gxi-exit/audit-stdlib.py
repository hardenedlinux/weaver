from pathlib import Path
import re,json,hashlib
out=Path(__file__).parent;root=Path('.data/dynamic-gxi-exit-20261020').resolve();oldLib=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current/lib/std');newLib=root/'lib-narrow/std'
rows=[]
def block(text,start):
 depth=0;quoted=False;escape=False
 for i in range(start,len(text)):
  c=text[i]
  if quoted:
   if escape:escape=False
   elif c=='\\':escape=True
   elif c=='"':quoted=False
  elif c=='"':quoted=True
  elif c=='(':depth+=1
  elif c==')':
   depth-=1
   if depth==0:return text[start:i+1]
 raise ValueError('unclosed')
def without_import(text):
 i=text.index('(import');b=block(text,i);return text[:i]+text[i+len(b):]
def exports(text):
 b=block(text,text.index('(%#export'));return sorted(re.findall(r'\(spec:\s+(\d+)\s+([^\s()]+)\s+([^\s()]+)\)',b))
for r in json.loads((out/'stdlib-source-snapshot.json').read_text()):
 p=Path(r['copy']);old=Path(r['original']).read_text();new=p.read_text();assert without_import(old)==without_import(new)
 rel=Path(r['path']).with_suffix('.ssi');a=oldLib/rel;b=newLib/rel;ea=exports(a.read_text());eb=exports(b.read_text());assert ea==eb,(r['path'],set(ea)-set(eb),set(eb)-set(ea))
 rows.append(dict(module='std/'+str(Path(r['path']).with_suffix('')),sourceBodiesIdenticalAfterRemovingOnlyImportForm=True,publicExportSpecs=ea,oldInterface=str(a),newInterface=str(b),oldInterfaceSha256=hashlib.sha256(a.read_bytes()).hexdigest(),newInterfaceSha256=hashlib.sha256(b.read_bytes()).hexdigest(),exportsIdentical=True))
(out/'stdlib-abi-audit.json').write_text(json.dumps(rows,indent=2)+'\n');print('PASS:',len(rows),'modules retain function/macro source bodies and public export phase/name/binding IDs')
