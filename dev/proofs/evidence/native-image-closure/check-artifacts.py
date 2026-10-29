from pathlib import Path
import json,hashlib,struct,uuid
out=Path(__file__).parent;root=Path('.data/native-image-closure-20261020').resolve();cache={}
def sha(p):
 p=Path(p);s=p.stat();k=(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns)
 if k not in cache:cache[k]=hashlib.sha256(p.read_bytes()).hexdigest()
 return cache[k]
objects=json.loads((out/'objects.json').read_text());by={r['module']:r for r in objects};partition=json.loads((out/'partition.json').read_text());control=json.loads((out/'control-partition.json').read_text());assert len(by)==238 and len(objects)==238
for groups in [partition,control]:
 flat=[n for g in groups for n in g];assert len(flat)==len(set(flat))==238 and set(flat)==set(by)
 for g in groups:
  defs=[s for n in g for s in by[n]['definitions']];assert len(defs)==len(set(defs))
for r in objects:
 assert sha(r['source'])==r['sourceSha256']==sha(r['snapshot']);assert sha(r['object'])==r['objectSha256'] and sha(r['generatedC'])==r['generatedCSha256'] and r['noForeignInitializers'] and r['noUndefinedLinkEntries']
images=json.loads((out/'images.json').read_text());cold=json.loads((out/'launcher-cold-images.json').read_text());allImages=images+cold;allIDs=[];sections=0
for im in allImages:
 path=Path(im['path']);assert sha(path)==im['sha256']
 with path.open('rb') as f:
  h=f.read(32);magic,cpu,subcpu,kind,ncmds,size,flags,reserved=struct.unpack('<IiiIIIII',h);commands=f.read(size)
 assert magic==0xfeedfacf and cpu==0x100000c and kind==8
 offset=0;uid=None
 for _ in range(ncmds):
  cmd,length=struct.unpack_from('<II',commands,offset);assert length>=8 and offset+length<=len(commands)
  if cmd==0x1b:uid=str(uuid.UUID(bytes=commands[offset+8:offset+24])).upper()
  if cmd==0x19:
   nsects=struct.unpack_from('<I',commands,offset+64)[0]
   for number in range(nsects):
    section=offset+72+number*80;stype=struct.unpack_from('<I',commands,section+64)[0]&0xff;assert stype not in [0x9,0xa,0x15,0x16],(path,stype);sections+=1
  offset+=length
 assert uid==im['uuid'].upper();allIDs.append(uid)
 for alias in im['aliases']:
  aliasPath=Path(alias['path'] if isinstance(alias,dict) else alias);assert aliasPath.stat().st_ino==path.stat().st_ino and aliasPath.stat().st_dev==path.stat().st_dev
  if isinstance(alias,dict):
   row=by[alias['module']];assert alias['entry']==row['entry'] and alias['sourceSha256']==row['sourceSha256'] and alias['objectSha256']==row['objectSha256']
assert len(allIDs)==len(set(allIDs))==620
base=json.loads((out/'inputs-before.json').read_text());cache.clear()
for n,h in base['byteInputs'].items():assert sha(n)==h,n
source=json.loads((out/'source-inputs.json').read_text());assert all(sha(n)==h for n,h in source.items())
identity=json.loads((out/'run-input-identity.json').read_text());assert sha(out/'plan.json')==identity['planSha256'] and sha(out/'run-matrix.py')==identity['controllerSha256']
newIdentity=json.loads((out/'launcher-cold-input-identity.json').read_text());assert sha(out/'launcher-cold-plan.json')==newIdentity['planSha256'] and sha(out/'run-launcher-cold.py')==newIdentity['controllerSha256'] and sha('/opt/homebrew/bin/gxi')==newIdentity['outerLauncherSha256']
result=dict(unchanged=True,completeConsumedBodyClosure=260,coveredExcludedNativeBodies=len(base['excludedNativeBodies']),selectedEntries=238,objects=238,candidateGroups=len(partition),controlGroups=len(control),uniqueUUIDs=620,validatedMachOSections=sections,nativeInitializerSectionTypesAbsent=[9,10,21,22],allAliasInodesBound=True,originalEntryAndSourceBindingsPreserved=True,allExpectedModulesExactlyOnce=True,checkedBeforeByteInputs=len(base['byteInputs']),trustedCompilerAndSingleWriterAssumed=True)
(out/'artifact-check.json').write_text(json.dumps(result,indent=2)+'\n');(out/'inputs-after-final.json').write_text(json.dumps(dict(unchanged=True,byteInputs=base['byteInputs'],coldPhysicalImages={im['path']:im['sha256'] for im in cold},sourceInputs=source),indent=2)+'\n');print(json.dumps(result))
