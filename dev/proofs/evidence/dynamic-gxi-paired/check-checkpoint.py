from pathlib import Path
import json,hashlib,re
p=Path(__file__).parent;matrix=json.loads((p/'matrix.json').read_text());plan=json.loads((p/'plan.json').read_text());assert len(matrix)==plan['sampleCount']==32
expected=[f'{family}-b{block}-{cell}-{use}' for family,block in plan['familyBlockOrder'] for cell in plan['blocks'][block] for use in plan['uses']];assert [r['label'] for r in matrix]==expected
for r in matrix:
 assert r['gateSeconds']==15 and r['forcedExit'] is False and r['exit']==0
 assert len(r['checks'])==len(set(r['checks']))==11
 assert r['fixtureSha256']=='68a27a0b594fda7aedab994c2d230464ddb2907176e25d9b8fe5837e24203750'
 assert r['cleanup']['moduleOpens']==r['cleanup']['moduleCloses'] and r['cleanup']['outstandingModuleRefs']==r['cleanup']['closeErrors']==r['cleanup']['overflow']==0
 assert r['qualified']==(not r['deadlineFailed'] and r['seconds']<=15)
 assert '# eventOverflow=0' in (p/r['label']/'timeline.tsv').read_text()
lean=json.loads((p/'clean-proof-receipt.json').read_text());assert len(lean['modules'])==17
assert all(r['exit']==0 and r['noSorryAx'] for r in lean['modules'])
assert lean['modules'][-1]['printedDeclarations']==11
for r in lean['modules']:assert hashlib.sha256(Path(r['source']).read_bytes()).hexdigest()==r['sourceSha256']
quint=json.loads((p/'api-commands.json').read_text());assert len(quint)==7 and all(r['exit']==0 for r in quint);assert sum(len(r.get('passed',[])) for r in quint)==14
inv=json.loads((p/'api-invocation.json').read_text());assert inv['exit']==0 and inv['expectedControls']==14
assert json.loads((p/'inputs-after.json').read_text())['unchanged']
assert len(json.loads((p/'historical-manifests.json').read_text()))==50
assert all(r['headMatches'] and r['workingMatches'] for r in json.loads((p/'source-currentness.json').read_text()))
assert any(r['cell']=='D' and r['use']=='first' and not r['qualified'] for r in matrix)
identity=json.loads((p/'identity-audit.json').read_text());assert identity['randomUUIDs']==420 and identity['distinctInodes']==840 and len(identity['executableLayouts'])==105
launcher=json.loads((p/'launcher.json').read_text());assert len(launcher)==4 and all(r['exit']==0 and r['gateSeconds']==15 and not r['forcedExit'] for r in launcher)
diag=json.loads((p/'sampled-diagnostic/receipt.json').read_text());assert diag['exit']==0 and not diag['forcedExit'] and diag['excludedFromPairedTimings']
cold=json.loads((p/'sampled-cold-diagnostic/receipt.json').read_text());assert cold['exit']==0 and cold['excludedFromPairedTimings'] and not cold['forcedExit'] and cold['cleanup']['outstandingModuleRefs']==0
assert json.loads((p/'binary-attribution.json').read_text())['sdkSymbol']=='F_CHECK_LV'
result=dict(status='PAIRED_ATTRIBUTION_COMPLETE_COLD_DEADLINE_OPEN',samples=len(matrix),passes=sum(r['qualified'] for r in matrix),failures=[r['label'] for r in matrix if not r['qualified']],candidateFirstUse=[dict(label=r['label'],seconds=r['seconds'],passed=r['qualified']) for r in matrix if r['cell']=='D' and r['use']=='first'],gateSeconds=15,allNaturalExit=True,allTrackedModuleRefsClosed=True,freshLeanModules=17,newLeanDeclarations=11,quintControls=14,sourceReviewsCurrent=16,olderManifestsUnchanged=50,hostColdControlled=False,causalLatencySLA=False,gatewayImplemented=False,dependencyPinsChanged=False)
(p/'checkpoint-check.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
