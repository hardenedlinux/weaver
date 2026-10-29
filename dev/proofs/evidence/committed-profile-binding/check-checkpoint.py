from pathlib import Path
import json,hashlib,re,subprocess
out=Path(__file__).parent;sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
r=json.loads((out/'clean-proof-receipt.json').read_text());assert len(r['modules'])==13
for m in r['modules']:
 assert m['exit']==0 and m['noSorryAx'] and sha(Path(m['source']))==m['sourceSha256']
 assert sha(Path(r['compiledDirectory'])/(m['module']+'.olean'))==m['compiledSha256']
 text=(out/(m['module']+'.log')).read_text();assert 'sorryAx' not in text and 'error:' not in text
assert r['modules'][-1]['module']=='CommittedSemanticProfile' and r['modules'][-1]['printedDeclarations']==22
q=Path('proofs/qunit/CommittedSemanticProfile.qnt').read_text();tests=re.findall(r'^  run (\w+Test)=',q,re.M);assert len(tests)==24
faults=[x for x in tests if x.endswith('CounterexampleTest')];assert len(faults)==4
assert 'unsafe' not in re.search(r'^  action step:bool=(.*)',q,re.M).group(1)
api=json.loads((out/'api-commands.json').read_text());assert len(api)==10 and all(x['exit']==0 for x in api)
assert sorted(t for x in api for t in x.get('passed',[]))==sorted(tests)
assert all(x['typedIrUnchanged'] for x in api if x['label'].startswith('api-controls-'))
inv=json.loads((out/'api-invocation.json').read_text());assert inv['exit']==0 and inv['expectedControls']==24
for name,h in inv['inputs'].items():assert sha(Path(name))==h
parts=[];cert=json.loads((out/'bundle-certificate.json').read_text());assert sum(x['omittedAncestorRunDeclarations'] for x in cert)==99
for x in cert:
 p=Path(x['source']);assert sha(p)==x['sha256'];s=p.read_text()
 if x['omittedAncestorRunDeclarations']:s=''.join('\n' if re.match(r'^  run ',l) else l for l in s.splitlines(keepends=True))
 for module in ['LlmRouting','RoutineRoutingConfig','SemanticGatewaySlice']:s=s.replace(' from "./'+module+'"','')
 parts.append(s)
assert '\n'.join(parts)==(out/'bundle.qnt').read_text()
native=json.loads((out/'native-authoring.json').read_text());assert native['exit']==124 and native['watchdogSeconds']==15
assert sha(out/'native-authoring.ss')==native['sourceSha256']
text=(out/'native-authoring.log').read_text();assert len(re.findall(r'^CHECK .* PASS$',text,re.M))==11
assert 'duplicate-json-contract-accepted decoder-rejected' in text
controls=json.loads((out/'native-exit-controls.json').read_text());assert len(controls)==3 and all(x['exit']==0 for x in controls)
observed=json.loads((out/'native-observed.json').read_text());assert observed['exit']==124 and observed['watchdogSeconds']==15 and observed['completionOutputAtSeconds']<15
assert sha(out/'native-authoring.ss')==observed['sourceSha256']
identity=json.loads((out/'native-identity.json').read_text());assert identity['nativeQualification']==False and identity['observedProcessExit']==124
for name,h in identity['compiledArtifactsObservedAfterRun'].items():assert sha(Path(name))==h
review=json.loads((out/'source-currentness.json').read_text());assert len(review)==16 and all(x['headMatches'] and x['workingMatches'] for x in review)
for row in review:
 assert sha(Path(row['repository'])/row['path'])==row['currentWorkingSha256']
 assert subprocess.check_output(['git','-C',row['repository'],'rev-parse','HEAD'],text=True).strip()==row['currentHead']
for row in identity['sources']:assert sha(Path(row['path']))==row['sha256']
assert len(json.loads((out/'historical-manifests.json').read_text()))==47
assert 'PASS: exported 4 Org documents' in (out/'org-export.log').read_text()
org='\n'.join(p.read_text() for p in Path('docs/50-59-research-program/52-committed-profile-binding').glob('*.org'))
lean=Path('proofs/lean/CommittedSemanticProfile.lean').read_text()
for name in ['profile_retained','initialized_safe','resolved_node_unique','recovery_cannot_select_other_node','original_record_covers_full_profile','actual_route_preserves_committed_capability','actual_semantic_use_keeps_published_schema']:
 assert name in org and ('theorem '+name) in lean
result=dict(status='FORMAL_AND_DOCUMENT_CHECKS_PASS_NATIVE_NATURAL_EXIT_OPEN',leanDeclarations=22,freshCompiledModules=13,quintControls=24,guardedControls=20,deliberateFaultControls=4,officialPhases=10,nativeContractOutputs=11,nativeDuplicateKeyRejection=True,nativeProcessExit=124,instrumentedNativeExit=124,nativeIndependentControls=3,nativeQualification=False)
(out/'checkpoint-check.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS: formal/source/document evidence checks; native qualification OPEN with retained exit 124, not promoted to pass')
