from pathlib import Path
import hashlib,json,subprocess
ROOT=Path.cwd();OUT=ROOT/'proofs/evidence/native-gerbil-exit'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
cache={};seals=[]
for p in sorted([*Path('specs/evidence').glob('*/SHA256SUMS'),*Path('proofs/evidence').glob('*/SHA256SUMS')]):
 if p.parent.resolve()==OUT:continue
 count=0
 for line in p.read_text().splitlines():
  expected,name=line.split('  ',1)
  if name not in cache:cache[name]=sha(Path(name))
  assert cache[name]==expected,(p,name)
  count+=1
 seals.append(dict(path=str(p),sha256=sha(p),targets=count))
assert len(seals)==48,len(seals)
(OUT/'historical-manifests.json').write_text(json.dumps(seals,indent=2)+'\n')
sourceRows=json.loads(Path('proofs/evidence/routine-routing-config/source-review.json').read_text());current=[]
for r in sourceRows:
 head=subprocess.check_output(['git','-C',r['repository'],'rev-parse','HEAD'],text=True).strip();p=Path(r['repository'])/r['path'];h=sha(p)
 current.append(dict(id=r['id'],repository=r['repository'],path=r['path'],reviewedHead=r['revision'],currentHead=head,headMatches=head==r['revision'],reviewedWorkingSha256=r['sha256'],currentWorkingSha256=h,workingMatches=h==r['sha256'],reviewedWorkingEqualsHead=r['workingEqualsHead']))
(OUT/'source-currentness.json').write_text(json.dumps(current,indent=2)+'\n')
receipts=[]
for category,name in [('llm-routing','final-receipt.json'),('llm-attempt-ledger','receipt.json'),('llm-semantic-contract','receipt.json'),('llm-authoritative-scope','receipt.json'),('llm-subject-authority','receipt.json'),('routine-routing-config','receipt.json')]:
 p=Path('proofs/evidence')/category/name;x=json.loads(p.read_text());receipts.append(dict(path=str(p),sha256=sha(p),recordedStatus=x.get('status'),recordedScope=x.get('scope'),freshlyRerun=False))
(OUT/'selected-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
scan=subprocess.run(['rg','--files','-g','*.go','-g','*.rs','-g','*.ss','-g','!proofs/**','-g','!specs/**','-g','!.data/**'],text=True,capture_output=True)
assert scan.returncode in (0,1),scan.stderr
ordinary=scan.stdout.splitlines()
(OUT/'workspace-snapshot.json').write_text(json.dumps(dict(cwd=str(ROOT),branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),auditDate='2026-10-20',ordinaryGatewaySourceCandidates=ordinary,ordinarySourceBoundary='Normal rg inventory outside proof/spec directories and ignored research clones',historicalManifests=len(seals),uniqueHistoricalByteTargets=len(cache),sourceFiles=len(current),currentSourceMatches=sum(r['headMatches'] and r['workingMatches'] for r in current)),indent=2)+'\n')
print('PASS: 48 historical manifests;',len(cache),'unique byte targets;',len(current),'source-currentness observations;',len(receipts),'sealed receipt classifications')
