from pathlib import Path
import json,hashlib,re,subprocess
out=Path(__file__).parent;sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
r=json.loads((out/'clean-proof-receipt.json').read_text());assert len(r['modules'])==14
for m in r['modules']:
 assert m['exit']==0 and m['noSorryAx'] and sha(Path(m['source']))==m['sourceSha256']
 assert sha(Path(r['compiledDirectory'])/(m['module']+'.olean'))==m['compiledSha256']
 text=(out/(m['module']+'.log')).read_text();assert 'sorryAx' not in text and 'error:' not in text
assert r['modules'][-1]['module']=='NativeExitQualification' and r['modules'][-1]['printedDeclarations']==9
q=Path('proofs/qunit/NativeExitQualification.qnt').read_text();tests=re.findall(r'^  run (\w+Test)=',q,re.M);assert len(tests)==12
assert len([x for x in tests if x.endswith('CounterexampleTest')])==3
assert 'unsafe' not in re.search(r'^  action step:bool=(.*)',q,re.M).group(1)
api=json.loads((out/'api-commands.json').read_text());assert len(api)==6 and all(x['exit']==0 for x in api)
assert sorted(t for x in api for t in x.get('passed',[]))==sorted(tests)
assert all(x['typedIrUnchanged'] for x in api if x['label'].startswith('api-controls-'))
inv=json.loads((out/'api-invocation.json').read_text());assert inv['exit']==0 and inv['expectedControls']==12
for name,h in inv['inputs'].items():assert sha(Path(name))==h
before=json.loads((out/'native-inputs-before.json').read_text());after=json.loads((out/'native-inputs-after.json').read_text())
assert after['unchanged'] and before['byteInputs']==after['byteInputs']
for name,h in before['byteInputs'].items():assert sha(Path(name))==h,name
assert len(before['modules'])==39
for m in before['modules']:
 assert sha(Path(m['source']))==m['sourceSha256'] and sha(Path(m['interface']))==m['interfaceSha256']
for m in before['reusedInstalledLinkObjects']:assert sha(Path(m['path']))==m['sha256']
for name,h in before['trustedToolsAndRuntime'].items():assert sha(Path(name))==h
snapshot=json.loads((out/'source-snapshot.json').read_text())
for row in snapshot['records']:assert sha(Path(row['snapshot']))==row['sha256']
assert sha(Path(before['unchangedCorePackage']['path']))==before['unchangedCorePackage']['sha256']
assert before['pooPin']=='fdeadfa40ca5cee5fe20308985aef1577f2eb49b'
original=before['originalFixture'];assert sha(Path(original['path']))==original['sha256']=='68a27a0b594fda7aedab994c2d230464ddb2907176e25d9b8fe5837e24203750'
assert sha(out/'owned-sources/fixture.ss')==original['sha256']
for name in ['entry.ss','fixture.ss']:
 assert (out/'owned-sources'/name).read_bytes()==Path(snapshot['root'],'source/weaver-native',name).read_bytes()
for name in ['canary.scm','cleanup.c']:
 assert (out/'owned-sources'/name).read_bytes()==Path('.data/native-gerbil-canary-20261020',name).read_bytes()
checks={'scheme-object-contract','native-json-contract','native-negative-ceiling','native-boolean-ceiling','native-string-ceiling','native-null-ceiling','native-unknown-authority-field','native-changed-node','native-overflow-ceiling','native-empty-targets','native-duplicate-targets'}
runs=json.loads((out/'qualified-stable/qualified-runs.json').read_text());assert len(runs)==3 and len({r['pid'] for r in runs})==3
for i,row in enumerate(runs):
 assert row['exit']==0 and row['qualified'] and row['budgetSeconds']==15 and row['seconds']<=15 and row['forcedExit']==False
 assert set(row['checkNames'])==checks and row['cleanup']=='LU'
 assert (out/f'qualified-stable/cleanup-{i}.txt').read_text()=='LU'
 text=(out/f'qualified-stable/qualified-{i}.log').read_text()
 assert 'OBSERVATION duplicate-json-contract-accepted decoder-rejected' in text and 'NATIVE-MAIN-RETURN' in text
 assert row['binarySha256']==sha(Path(row['args'][0]))
for name in ['link-public-load.json','canary-build.json']:assert json.loads((out/name).read_text())['exit']==0
assert json.loads((out/'link-aot.json').read_text())['exit']==70
# Diagnostic late exit must remain a failed unchanged deadline.
for d in ['unsandboxed-diagnostic','post-check-diagnostic']:
 r=json.loads((out/d/'installed-diagnostic.json').read_text());assert r['observedProcessExit']==0 and not r['gate']['withinBudget'] and r['nativeAcceptanceBudgetSeconds']==15 and not r['forcedNativeExit']
review=json.loads((out/'source-currentness.json').read_text());assert len(review)==16 and all(x['headMatches'] and x['workingMatches'] for x in review)
for row in review:
 assert sha(Path(row['repository'])/row['path'])==row['currentWorkingSha256']
 assert subprocess.check_output(['git','-C',row['repository'],'rev-parse','HEAD'],text=True).strip()==row['currentHead']
assert len(json.loads((out/'historical-manifests.json').read_text()))==48
assert 'PASS: exported 4 Org documents' in (out/'org-export.log').read_text()
assert '180 English Org documents' in (out/'document-inventory.log').read_text()
org='\n'.join(p.read_text() for p in Path('docs/50-59-research-program/53-native-gerbil-exit').glob('*.org'))
lean=Path('proofs/lean/NativeExitQualification.lean').read_text()
for name in ['qualification_preserves_cleanup','qualification_preserves_actual_checks','late_natural_exit_still_fails','wrong_source_is_not_qualified','live_handle_blocks_qualification','natural_pass_still_needs_gateway_policy']:
 assert name in org and 'theorem '+name in lean
result=dict(status='BOUNDED_AOT_NATIVE_NATURAL_EXIT_QUALIFIED',scope='Isolated native verification entry only; ordinary dynamic gxi deadline remains failed; no Gateway implementation or full toolchain rebuild',nativeProcesses=3,nativeBudgetSeconds=15,nativeSeconds=[r['seconds'] for r in runs],nativeCheckNames=11,nativeCleanup='LU',sourceInterfaces=39,stableNativeInputs=len(before['byteInputs']),quintControls=12,deliberateFaultControls=3,officialPhases=6,leanDeclarations=9,freshCompiledModules=14,historicalManifests=48,dependenciesChanged=False)
(out/'checkpoint-check.json').write_text(json.dumps(result,indent=2)+'\n');print('PASS: bounded AOT native entry qualified; preserved cleanup, fixed deadline, source identity, formal composition and failed dynamic controls')
