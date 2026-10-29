from pathlib import Path
import csv,json,hashlib
out=Path(__file__).parent;rows=json.loads((out/'matrix.json').read_text());plan=json.loads((out/'plan.json').read_text());assert len(rows)==16;expected=[f'b{b}-{role}-{use}' for b,order in enumerate(plan['blocks']) for role in order for use in plan['uses']];assert [r['label'] for r in rows]==expected
contrasts=[];index={(r['block'],r['role'],r['use']):r for r in rows}
for b in range(4):
 for use in plan['uses']:
  a=index[b,'control',use];z=index[b,'candidate',use];contrasts.append(dict(block=b,use=use,controlMinusCandidateSeconds=a['seconds']-z['seconds'],control=a['label'],candidate=z['label']))
parts=[]
for r in rows:
 timeline=(out/r['label']/'timeline.tsv').read_text();events=list(csv.DictReader(timeline.split('#')[0].splitlines(),delimiter='\t'));seen=set();groups={}
 for e in events:
  if e['op']!='L' or e['tracked']!='1':continue
  f=Path(e['path']);st=f.stat();identity=(st.st_dev,st.st_ino);fresh=identity not in seen;seen.add(identity);tag=('selected' if f'/g{r["block"]}/{r["role"]}/aliases/' in e['path'] else 'fallback')+('-first-inode-request' if fresh else '-repeat-alias')
  groups.setdefault(tag,dict(count=0,seconds=0));groups[tag]['count']+=1;groups[tag]['seconds']+=int(e['duration_ns'])/1e9
 parts.append(dict(sample=r['label'],groups=groups))
candidates=[r for r in rows if r['role']=='candidate'];closed=all(r['cleanup']['moduleOpens']==r['cleanup']['moduleCloses']==260 and r['cleanup']['outstandingModuleRefs']==r['cleanup']['closeErrors']==r['cleanup']['overflow']==0 and r['exactModulePaths'] for r in rows)
result=dict(status='ORDINARY_DYNAMIC_SELECTED_IMAGE_GATE_CLOSED' if all(r['qualified'] for r in candidates) and closed else 'CANDIDATE_SERIES_FAILED_OPEN',samples=16,candidateSamples=8,candidatePasses=sum(r['qualified'] for r in candidates),candidateSeconds=[r['seconds'] for r in candidates],failedSamples=[r['label'] for r in rows if not r['qualified']],allNaturalExit=all(r['exit']==0 for r in rows),allExactModulePaths=all(r['exactModulePaths'] for r in rows),allTrackedResourcesClosed=closed,peakImages={role:sorted({r['cleanup']['peakDyldImages'] for r in rows if r['role']==role}) for role in ['control','candidate']},contrasts=contrasts,loadGroups=parts,gateSeconds=15,hostColdControlled=False,globalLatencyGuarantee=False,intervalDefinition='Wrapper interval around the real API plus observer bookkeeping and scheduling, not an isolated syscall duration')
(out/'analysis.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
