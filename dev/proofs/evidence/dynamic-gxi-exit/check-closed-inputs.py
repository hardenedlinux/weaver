from pathlib import Path
import json,hashlib,subprocess
out=Path(__file__).parent
if (out/"SHA256SUMS").exists() and (out/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation is immutable; reproduce in fresh isolation and evidence directories.")
root=Path('.data/dynamic-gxi-exit-20261020').resolve();home=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current');old=json.loads((out/'inputs-before.json').read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
inputs=dict(old['byteInputs']);observed=json.loads((out/'packed-observed/receipt.json').read_text())['modules'];interfaces={}
for name,path in observed.items():
 inputs[path]=sha(Path(path));base=name.split('~')[0]
 for lib in [root/'lib-narrow',root/'lib-native',home/'lib']:
  p=lib/(base+'.ssi')
  if p.is_file():interfaces[str(p)]=sha(p);break
for p in [home/'bin/gxi',home/'bin/gsc',home/'bin/gambuild-C',home/'include/gambit.h']:inputs[str(p.resolve())]=sha(p)
inputs.update(interfaces)
(out/'closed-inputs-before.json').write_text(json.dumps(dict(byteInputs=inputs,observedNativeBodies=len(observed),interfaces=len(interfaces),scope='Owned source/artifacts plus complete observed Scheme native-module paths/interfaces and installed tool ABI files; not a transitive OS dylib seal'),indent=2)+'\n')
s=(out/'run-raw-observed.py').read_text().replace('run-raw-original-observed','run-raw-closed').replace('raw-original-observed.log','raw-closed.log').replace('raw-original-observed.json','raw-closed.json').replace('raw-module-cleanup.json','raw-closed-module-cleanup.json');(out/'run-raw-closed.py').write_text(s)
r=subprocess.run(['python3',str(out/'run-raw-closed.py')]);assert r.returncode==0
for name,h in inputs.items():assert sha(Path(name))==h,name
for name,h in old['trustedRuntimeAndCompiler'].items():assert sha(Path(name))==h
assert sha(Path(old['existingCorePackage']['path']))==old['existingCorePackage']['sha256']
(out/'inputs-after.json').write_text(json.dumps(dict(unchanged=True,ownedByteInputs=old['byteInputs'],closedByteInputs=inputs,closedCount=len(inputs),observedNativeBodies=len(observed),scope='All owned inputs and observed native module/interface bytes unchanged across the final exact-original-script check'),indent=2)+'\n');print('CLOSED INPUT STABILITY PASS',len(inputs))
