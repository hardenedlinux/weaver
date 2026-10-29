from pathlib import Path
import json,csv,hashlib
p=Path(__file__).parent;rows=json.loads((p/'matrix.json').read_text());assert len(rows)==32
index={(r['family'],r['block'],r['cell'],r['use']):r for r in rows};assert len(index)==32
contrasts=[]
for family in ['stable','uuid']:
 for block in [0,1]:
  for use in ['first','repeat']:
   for name,a,b in [('packing-broad','A','C'),('packing-narrow','B','D'),('imports-independent','A','B'),('imports-packed','C','D')]:
    x=index[family,block,a,use];y=index[family,block,b,use]
    contrasts.append(dict(family=family,block=block,use=use,contrast=name,control=x['label'],candidate=y['label'],controlMinusCandidateSeconds=x['seconds']-y['seconds'],bothQualified=x['qualified'] and y['qualified']))
repeat=[]
for family in ['stable','uuid']:
 for block in [0,1]:
  for cell in 'ABCD':
   a=index[family,block,cell,'first'];b=index[family,block,cell,'repeat'];repeat.append(dict(family=family,block=block,cell=cell,firstMinusRepeatSeconds=a['seconds']-b['seconds']))
intervals=[]
for r in rows:
 ts=list(csv.DictReader((p/r['label']/'timeline.tsv').read_text().split('#')[0].splitlines(),delimiter='\t'))
 for e in ts:
  if e['tracked']=='1':intervals.append(dict(sample=r['label'],op=e['op'],startSeconds=int(e['start_ns'])/1e9,durationSeconds=int(e['duration_ns'])/1e9,path=e['path']))
perSample=[]
for r in rows:
 ts=list(csv.DictReader((p/r['label']/'timeline.tsv').read_text().split('#')[0].splitlines(),delimiter='\t'))
 groups={};seen=set()
 for e in ts:
  if e['op']!='L' or not e['path'] or not Path(e['path']).is_file():continue
  st=Path(e['path']).stat();key=(st.st_dev,st.st_ino);fresh=key not in seen;seen.add(key)
  selected='/g'+str(r['block'])+'/'+r['cell']+'/' in e['path']
  tag=('selected' if selected else 'common')+('-first-mapping-request' if fresh else '-repeat-alias')
  groups.setdefault(tag,dict(count=0,seconds=0));groups[tag]['count']+=1;groups[tag]['seconds']+=int(e['duration_ns'])/1e9
 perSample.append(dict(sample=r['label'],groups=groups,qualification='First request by observed inode; not an OS observer cache-miss assertion'))
summary=dict(perSampleLoadGroups=perSample,samples=len(rows),passes=sum(r['qualified'] for r in rows),failures=[r['label'] for r in rows if not r['qualified']],contrasts=contrasts,firstRepeat=repeat,longestCalls=sorted(intervals,key=lambda r:r['durationSeconds'],reverse=True)[:20],peakImages={cell:sorted({r['cleanup']['peakDyldImages'] for r in rows if r['cell']==cell}) for cell in 'ABCD'},cleanupComplete=all(r['cleanup']['moduleOpens']==r['cleanup']['moduleCloses'] and r['cleanup']['outstandingModuleRefs']==0 and r['cleanup']['closeErrors']==0 for r in rows),hostColdControlled=False,universalDeadlineProven=False,intervalDefinition='Wrapper interval around real dyld API plus local bookkeeping and scheduling; not pure syscall duration')
(p/'analysis.json').write_text(json.dumps(summary,indent=2)+'\n')
# Verify all native timed inputs and inherited runtime/source inventory.
inputs=json.loads((p/'uuid-inputs-before.json').read_text());inputs.update(json.loads((p/'inherited-input-inventory.json').read_text())['byteInputs']);assert all(hashlib.sha256(Path(n).read_bytes()).hexdigest()==h for n,h in inputs.items())
(p/'inputs-after.json').write_text(json.dumps(dict(unchanged=True,count=len(inputs),byteInputs=inputs),indent=2)+'\n')
print('SAMPLES',summary['samples'],'PASS',summary['passes'],'FAIL',summary['failures'],'PEAK',summary['peakImages'])
for c in contrasts:print(c['family'],c['block'],c['use'],c['contrast'],round(c['controlMinusCandidateSeconds'],3))
