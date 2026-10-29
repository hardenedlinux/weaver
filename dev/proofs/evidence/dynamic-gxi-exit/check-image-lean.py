from pathlib import Path
import json,os,time,subprocess,hashlib,re
out=Path(__file__).parent;r=json.loads((out/'clean-proof-receipt.json').read_text());p=Path('proofs/lean/DynamicImageCustody.lean');args=['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(Path(r['compiledDirectory'])/'DynamicImageCustody.olean'),str(p)];t=time.monotonic()
with (out/'DynamicImageCustody.log').open('w') as f:c=subprocess.run(args,env=dict(os.environ,LEAN_PATH=r['compiledDirectory']),stdout=f,stderr=subprocess.STDOUT,timeout=20).returncode
s=(out/'DynamicImageCustody.log').read_text();row=dict(module='DynamicImageCustody',source=str(p),sourceSha256=hashlib.sha256(p.read_bytes()).hexdigest(),args=args,exit=c,seconds=round(time.monotonic()-t,3),noSorryAx='sorryAx' not in s,printedDeclarations=len(re.findall(r"^'Weaver\.",s,re.M)))
if c==0:row['compiledSha256']=hashlib.sha256((Path(r['compiledDirectory'])/'DynamicImageCustody.olean').read_bytes()).hexdigest()
(out/'image-lean-check.json').write_text(json.dumps(row,indent=2)+'\n');print('image lean',c)
if c==0:
 r['modules']=[m for m in r['modules'] if m['module']!='DynamicImageCustody']+[row]
 for field in ['sourceClosure','targets']:
  if 'DynamicImageCustody' not in r[field]:r[field].append('DynamicImageCustody')
 (out/'clean-proof-receipt.json').write_text(json.dumps(r,indent=2)+'\n')
raise SystemExit(c)
