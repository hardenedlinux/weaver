from pathlib import Path
import json,hashlib,subprocess,shutil
out=Path(__file__).parent
if (out/"SHA256SUMS").exists() and (out/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation is immutable; reproduce in fresh isolation and evidence directories.")
root=Path('.data/dynamic-gxi-exit-20261020').resolve();cache={}
def sha(p):
 st=p.stat();key=(st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns)
 if key not in cache:cache[key]=hashlib.sha256(p.read_bytes()).hexdigest()
 return cache[key]
files=[]
for folder in ['lib-native','lib-narrow','dynamic-images','canary','source','narrow-source']:
 files.extend(p for p in (root/folder).rglob('*') if p.is_file())
files.extend([root/'module-cleanup-observer.dylib',root/'fixture.ss'])
inputs={str(p):sha(p) for p in files}
core=Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/core');runtime=Path('/opt/homebrew/bin/gxi').resolve();binary=(runtime.parent.parent/'current/bin/gxi').resolve();tools={str(p):sha(p) for p in [runtime,binary,Path('/opt/homebrew/bin/gcc-16').resolve()]}
for row in json.loads((out/'stdlib-source-snapshot.json').read_text()):assert sha(Path(row['copy']))==row['candidateSha256'] and sha(Path(row['original']))==row['originalSha256']
old=json.loads(Path('proofs/evidence/native-gerbil-exit/source-snapshot.json').read_text())
for row in old['records']:
 new=root/'source'/Path(row['snapshot']).relative_to(Path(old['root'])/'source');assert sha(new)==row['sha256']
original=Path('proofs/evidence/committed-profile-binding/native-authoring.ss');assert (root/'fixture.ss').read_bytes()==original.read_bytes()
result=dict(byteInputs=inputs,trustedRuntimeAndCompiler=tools,sourceSnapshotRecords=len(old['records']),coreHead=subprocess.check_output(['git','-C',str(core),'rev-parse','HEAD'],text=True).strip(),existingCorePackage=dict(path=str(core/'gerbil.pkg'),sha256=sha(core/'gerbil.pkg')),fixtureSha256=sha(original),coreInterfaces=len(list((root/'lib-native').rglob('*.ssi'))),stdlibInterfaces=len(list((root/'lib-narrow').rglob('*.ssi'))),boundary='Original fixture; complete retained Core/POO source snapshot; freshly compiled native Core/POO and narrowed stdlib; multi-entry dynamic images; installed interpreter unchanged')
(out/'inputs-before.json').write_text(json.dumps(result,indent=2)+'\n');print('CAPTURED',len(inputs),'native/source inputs; source interfaces',result['coreInterfaces'],result['stdlibInterfaces'])
