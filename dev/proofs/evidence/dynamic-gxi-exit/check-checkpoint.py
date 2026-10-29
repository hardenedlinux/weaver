from pathlib import Path
import json,hashlib,re,subprocess
out=Path(__file__).parent;cache={}
def sha(p):
 p=Path(p);st=p.stat();key=(st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns)
 if key not in cache:cache[key]=hashlib.sha256(p.read_bytes()).hexdigest()
 return cache[key]
def load(p):return json.loads((out/p).read_text())
lean=load('clean-proof-receipt.json');assert len(lean['modules'])==16
for r in lean['modules']:
 assert r['exit']==0 and r['noSorryAx'] and sha(r['source'])==r['sourceSha256']
 assert sha(Path(lean['compiledDirectory'])/(r['module']+'.olean'))==r['compiledSha256']
 text=(out/(r['module']+'.log')).read_text();assert 'sorryAx' not in text and 'error:' not in text
assert lean['modules'][-2]['module']=='NativeDynamicImportBoundary' and lean['modules'][-2]['printedDeclarations']==9
assert lean['modules'][-1]['module']=='DynamicImageCustody' and lean['modules'][-1]['printedDeclarations']==9
aux=load('research-thin-loader-lean.json');assert aux['exit']==0 and sha(aux['source'])==aux['sourceSha256']
for folder,name in [('', 'NativeDynamicImportBoundary'),('image-proof/','DynamicImageCustody')]:
 source=Path('proofs/qunit')/(name+'.qnt');text=source.read_text();tests=re.findall(r'^  run (\w+Test)=',text,re.M);expected=15 if name=='NativeDynamicImportBoundary' else 18;assert len(tests)==expected
 assert len([n for n in tests if n.endswith('CounterexampleTest')])==4
 assert 'unsafe' not in re.search(r'^  action step:bool=(.*)',text,re.M).group(1)
 api=load(folder+'api-commands.json');assert len(api)==(2+(expected+2)//3) and all(r['exit']==0 for r in api)
 assert sorted(t for r in api for t in r.get('passed',[]))==sorted(tests)
 assert all(r['typedIrUnchanged'] for r in api if r['label'].startswith('api-controls-'))
 inv=load(folder+'api-invocation.json');assert inv['exit']==0 and inv['expectedControls']==expected
 for path,h in inv['inputs'].items():assert sha(path)==h
inputs=load('inputs-before.json');after=load('inputs-after.json');closed=load('closed-inputs-before.json');assert inputs['byteInputs']==after['ownedByteInputs'] and closed['byteInputs']==after['closedByteInputs'] and after['unchanged']
for path,h in after['closedByteInputs'].items():assert sha(path)==h,path
assert inputs['coreInterfaces']==38 and inputs['stdlibInterfaces']==8 and inputs['sourceSnapshotRecords']==1003
assert inputs['fixtureSha256']=='68a27a0b594fda7aedab994c2d230464ddb2907176e25d9b8fe5837e24203750'
assert sha(inputs['existingCorePackage']['path'])==inputs['existingCorePackage']['sha256']
assert load('source-build.json')['exit']==0 and load('narrow-build.json')['exit']==0
assert len(re.findall(r'^COMPILE-DONE ',(out/'source-build.log').read_text(),re.M))==38
assert len(re.findall(r'^COMPILE-DONE ',(out/'narrow-build.log').read_text(),re.M))==8
abi=load('stdlib-abi-audit.json');assert len(abi)==8 and all(r['exportsIdentical'] and r['sourceBodiesIdenticalAfterRemovingOnlyImportForm'] for r in abi)
for row in abi:assert sha(row['newInterface'])==row['newInterfaceSha256'] and sha(row['oldInterface'])==row['oldInterfaceSha256']
plan=load('dynamic-images.json');entries=load('image-entry-audit.json');assert plan['exit']==0 and plan['modules']==98 and len(plan['images'])==7 and sum(len(r['members']) for r in entries)==98
for row in entries:assert row['noCInitOrTermSections']
for row in plan['images']:
 assert sha(row['image'])==row['sha256'] and row['noCInitializersOrDestructors']
 for alias in row['aliases']:assert Path(alias).stat().st_ino==Path(row['image']).stat().st_ino and sha(alias)==row['sha256']
original=Path('.data/dynamic-gxi-exit-20261020/fixture.ss').read_bytes();expectedChecks=set(re.findall(rb"\(check '([\w-]+)",original));assert len(expectedChecks)==11
for label in ['qualified-0','qualified-1','qualified-2','packed-observed','quiet-a1','quiet-b1','quiet-b2','quiet-a2']:
 row=load(label+'/receipt.json');assert row['qualified'] and row['exit']==0 and row['seconds']<=15 and row['gateSeconds']==15 and not row['forcedExit'] and row['cleanup']=='LU'
 assert {x.encode() for x in row['checks']}==expectedChecks
 assert Path(row['auditedSource']).read_bytes().startswith(original+b'\n')
 assert row['fixtureSha256']==inputs['fixtureSha256'] and row['nativeBodyModules']==260
 if '/dynamic-images' in row['loadpath']:assert sum('/dynamic-images/' in p for p in row['modules'].values())==98
for label,countsPath in [('raw-original',None),('raw-original-observed','raw-module-cleanup.json'),('raw-closed','raw-closed-module-cleanup.json')]:
 row=load(label+'.json');assert row['qualified'] and row['exit']==0 and row['seconds']<=15 and row['gateSeconds']==15 and not row['forcedExit'] and row['fixtureSha256']==inputs['fixtureSha256']
 if countsPath:
  c=load(countsPath);assert c['moduleOpens']==260 and c['moduleCloses']==260 and c['outstandingModuleRefs']==c['closeErrors']==c['overflow']==0
for label in ['packed-observed','unpacked-observed','quiet-a1','quiet-a2','quiet-b1','quiet-b2']:
 c=load(label+'/module-cleanup.json');assert c['moduleOpens']==c['moduleCloses']==261 and c['outstandingModuleRefs']==c['closeErrors']==c['overflow']==0
assert load('packed-observed/module-cleanup.json')['peakDyldImages']==216 and load('unpacked-observed/module-cleanup.json')['peakDyldImages']==307
lazy=load('lazy-entry-control.json');assert lazy['qualified'] and lazy['sharedInode'] and lazy['lines']==lazy['expected'] and lazy['cleanup']=='LU' and lazy['seconds']<=15
assert not load('isolated.json')['withinBudget'] and load('isolated.json')['exit']==0
for label in ['candidate-0','candidate-1','candidate-2','narrowed-0','matched-control-first']:assert not load(label+'/receipt.json')['qualified']
late=load('matched-control-first/late-observation.json');assert late['originalExitStatus'] is None and late['cleanupCounter']['outstandingModuleRefs']==0
order=load('module-path-and-order-audit.json');assert order['logicalModuleKeysEqual'] and not order['fullOrdinalEqualityWithUnpacked']
assert len(load('historical-manifests.json'))==49
for r in load('source-currentness.json'):
 assert r['headMatches'] and r['workingMatches'] and sha(Path(r['repository'])/r['path'])==r['currentWorkingSha256']
 assert subprocess.check_output(['git','-C',r['repository'],'rev-parse','HEAD'],text=True).strip()==r['currentHead']
assert '184 English Org documents' in (out/'document-inventory.log').read_text() and '71 D2/SVG pairs' in (out/'document-inventory.log').read_text()
assert 'PASS: exported 4 Org documents' in (out/'org-export.log').read_text()
canonical=lambda x:hashlib.sha256(json.dumps(x,sort_keys=True,separators=(',',':')).encode()).hexdigest()
closedDigest=canonical(closed['byteInputs']);old=canonical(json.loads(Path('proofs/evidence/native-gerbil-exit/native-inputs-before.json').read_text())['byteInputs']);assert closedDigest!=old
root=Path('.data/dynamic-gxi-exit-20261020').resolve()
context=dict(kind='exact-original-script-with-passive-observer',entrySha256=inputs['fixtureSha256'],loadPath=[str(root/n) for n in ['dynamic-images','lib-narrow','lib-native']],runtime=load('raw-closed.json')['args'][0],observerBinarySha256=sha(root/'module-cleanup-observer.dylib'),moduleEntryMapSha256=sha(out/'image-entry-audit.json'),gateSeconds=15)
profile=canonical(dict(closedNativeInputsSha256=closedDigest,executionContext=context))
nativeEntrySources={label:sha(load(label+'/receipt.json')['auditedSource']) for label in ['qualified-0','qualified-1','qualified-2','packed-observed','quiet-a1','quiet-b1','quiet-b2','quiet-a2']}
(out/'native-execution-profile.json').write_text(json.dumps(dict(closedNativeInputsSha256=closedDigest,executionContext=context,nativeExecutionProfileSha256=profile,auditedProgramDigests=nativeEntrySources,originalEntryDigest=inputs['fixtureSha256'],scope='Primary profile binds the exact original source and observed native execution. Audited programs have separate complete entry digests. Final recipe/proof/receipt identities are additionally covered by SHA256SUMS; this is local trusted-controller evidence, not cryptographic runtime attestation.'),indent=2)+'\n')
result=dict(status='ORDINARY_DYNAMIC_GXI_LOCAL_QUALIFIED',scope='Original interpreted source plus audited runs; isolated dependency/import and dynamic-image publication; host-wide timing variability not eliminated',gateSeconds=15,ordinaryAuditedSeconds=[load(f'qualified-{i}/receipt.json')['seconds'] for i in range(3)],exactOriginalSeconds=load('raw-original.json')['seconds'],completeInputRawSeconds=load('raw-closed.json')['seconds'],exactOriginalModuleLoads=260,exactOriginalModuleCloses=260,outstandingModuleRefs=0,coreSourceInterfaces=38,stdlibSourceInterfaces=8,packedEntries=98,sharedImages=7,closedInputByteTargets=len(closed['byteInputs']),nativeExecutionProfileSha256=profile,closedNativeInputsSha256=closedDigest,previousAotInputsSha256=old,freshLeanModules=16,importBoundaryDeclarations=9,imageCustodyDeclarations=9,quintControls=33,unsafeCounterexampleControls=8,officialPhases=15,historicalManifests=49,dependenciesChanged=False,globalInstallationChanged=False,gatewayImplemented=False,allHostLatencyCausallyResolved=False)
official=load('official-compiler-options.json');assert sha(official['owner'])==official['ownerSha256']
for flag in ['-fwrapv','-fno-strict-aliasing','-fno-trapping-math','-fno-math-errno','-foptimize-sibling-calls']:
 assert flag in official['options']['FLAGS_OBJ']
objects=load('official-object-build.json');assert len(objects)==98
for row in objects:
 assert row['exit']==0 and sha(row['object'])==row['objectSha256'] and sha(row['generatedC'])==row['generatedCSha256'] and sha(row['source'])==row['sourceSha256']
 for flag in official['options']['FLAGS_OPT']+official['options']['FLAGS_OBJ']+official['options']['DEFS_DYN']:assert flag in row['args']
primary=load('official-dynamic-images.json');assert primary['exit']==0 and primary['modules']==98 and len(primary['images'])==7
assert len(load('official-abi/image-entry-audit.json'))==7
for row in primary['images']:
 assert row['noCInitializersOrDestructors'] and sha(row['image'])==row['sha256']
 for alias in row['aliases']:assert sha(alias)==row['sha256'] and Path(alias).stat().st_ino==Path(row['image']).stat().st_ino
before2=load('official-abi/inputs-before.json');after2=load('official-abi/inputs-after.json');assert after2['unchanged'] and before2['byteInputs']==after2['byteInputs']
for path,h in after2['byteInputs'].items():assert sha(path)==h,path
for label in ['qualified-0','qualified-1','qualified-2','observed']:
 row=load('official-abi/'+label+'/receipt.json');assert row['qualified'] and row['exit']==0 and row['seconds']<=15 and row['gateSeconds']==15 and row['cleanup']=='LU' and not row['forcedExit']
 assert {x.encode() for x in row['checks']}==expectedChecks and row['nativeBodyModules']==260
 assert sum('/dynamic-images-official/' in path for path in row['modules'].values())==98
for label in ['raw-original','raw-original-observed']:
 row=load('official-abi/'+label+'.json');assert row['qualified'] and row['exit']==0 and row['seconds']<=15 and row['gateSeconds']==15 and not row['forcedExit'] and row['fixtureSha256']==inputs['fixtureSha256']
for name,expected in [('official-abi/raw-module-cleanup.json',260),('official-abi/observed/module-cleanup.json',261)]:
 row=load(name);assert row['moduleOpens']==row['moduleCloses']==expected and row['outstandingModuleRefs']==row['closeErrors']==row['overflow']==0
lazy2=load('official-abi/lazy-entry-control.json');assert lazy2['qualified'] and lazy2['seconds']<=15 and lazy2['lines']==lazy2['expected'] and lazy2['sharedInode']
context2=dict(context,loadPath=[str(root/n) for n in ['dynamic-images-official','lib-narrow','lib-native']],compilerOptionsSha256=sha(out/'official-compiler-options.json'),moduleEntryMapSha256=sha(out/'official-abi/image-entry-audit.json'))
closed2=canonical(before2['byteInputs']);profile2=canonical(dict(closedNativeInputsSha256=closed2,executionContext=context2));assert profile2!=profile
(out/'official-abi/native-execution-profile.json').write_text(json.dumps(dict(closedNativeInputsSha256=closed2,executionContext=context2,nativeExecutionProfileSha256=profile2,initialExploratoryProfileSha256=profile),indent=2)+'\n')
result.update(status='ORDINARY_DYNAMIC_GXI_OFFICIAL_OPTIONS_LOCAL_QUALIFIED',initialExploratorySeconds=result['ordinaryAuditedSeconds'],ordinaryAuditedSeconds=[load(f'official-abi/qualified-{i}/receipt.json')['seconds'] for i in range(3)],exactOriginalSeconds=load('official-abi/raw-original.json')['seconds'],completeInputRawSeconds=load('official-abi/raw-original-observed.json')['seconds'],closedInputByteTargets=len(before2['byteInputs']),nativeExecutionProfileSha256=profile2,closedNativeInputsSha256=closed2,officialCompilerOptions=True,primaryEvidence='official-abi/',scope='Exact original source through ordinary installed gxi and complete configured C options in the isolated native candidate; full cleanup preserved; host-wide latency variability not claimed eliminated')
(out/'checkpoint-check.json').write_text(json.dumps(result,indent=2)+'\n');print('PASS: exact original dynamic gxi, owned cleanup, complete input stability, distinct lazy entries, formal composition and preserved failures')
