"""Audit selected product proof source/import identity in a fresh isolated directory."""
from pathlib import Path
import re,json,hashlib,tempfile,subprocess,time,os
ROOT=Path.cwd();OUT=ROOT/'specs/evidence/research-program-audit-20261020'
targets=['LlmAuthoritativeScope','RoutineRoutingConfig'];order=[];visiting=set();paths={};imports={}
def source(name):
 ps=[p for base in ['proofs/lean','specs/lean'] if (p:=ROOT/base/(name+'.lean')).is_file()]
 assert len(ps)==1,(name,ps)
 return ps[0]
def visit(name):
 if name in order:return
 assert name not in visiting,name
 visiting.add(name);p=source(name);deps=[]
 for imported in re.findall(r'^import\s+([A-Za-z0-9_.]+)',p.read_text(),re.M):
  if imported in ['Std','Lean','Init']:continue
  deps.append(imported);visit(imported)
 imports[name]=deps;paths[name]=p;visiting.remove(name);order.append(name)
for n in targets:visit(n)
compiled=Path(tempfile.mkdtemp(prefix='weaver-research-proof-audit-'));records=[]
for name in order:
 p=paths[name];h=hashlib.sha256(p.read_bytes()).hexdigest();args=['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/(name+'.olean')),str(p.relative_to(ROOT))];t=time.monotonic()
 with (OUT/(name+'.log')).open('w') as log:
  try:code=subprocess.run(args,cwd=ROOT,env=dict(os.environ,LEAN_PATH=str(compiled)),stdout=log,stderr=subprocess.STDOUT,timeout=20).returncode
  except subprocess.TimeoutExpired:code=124
 text=(OUT/(name+'.log')).read_text();assert hashlib.sha256(p.read_bytes()).hexdigest()==h
 record=dict(module=name,source=str(p.relative_to(ROOT)),sourceSha256=h,imports=imports[name],args=args,exit=code,seconds=round(time.monotonic()-t,3),watchdogSeconds=20,noSorryAx='sorryAx' not in text,printedDeclarations=len(re.findall(r"^'Weaver\.",text,re.M)))
 if code==0:record['compiledSha256']=hashlib.sha256((compiled/(name+'.olean')).read_bytes()).hexdigest()
 records.append(record);(OUT/'clean-proof-receipt.json').write_text(json.dumps(dict(targets=targets,compiledDirectory=str(compiled),modules=records,sourceClosure=order),indent=2)+'\n');print(name,code,flush=True)
 if code or 'sorryAx' in text or 'error:' in text:raise SystemExit(code or 1)
print('PASS:',len(order),'modules built from source in one fresh directory; each source and compiled artifact hashed')
