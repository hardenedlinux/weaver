from pathlib import Path
import hashlib,json,shutil,subprocess
out=Path(__file__).parent;root=Path('.data/native-gerbil-exit-20261020').resolve();sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
modules=[]
for p in sorted((root/'lib-clean').rglob('*.ssi')):
 name=str(p.relative_to(root/'lib-clean'))[:-4];s=root/'source'/(name+'.ss');assert s.is_file(),s
 modules.append(dict(module=name,source=str(s),sourceSha256=sha(s),interface=str(p),interfaceSha256=sha(p)))
assert len(modules)==39
fixture=root/'source/weaver-native/fixture.ss';original=Path('proofs/evidence/committed-profile-binding/native-authoring.ss')
assert fixture.read_bytes()==original.read_bytes()
source=json.loads((out/'source-snapshot.json').read_text())
for row in source['records']:assert sha(Path(row['snapshot']))==row['sha256']
files=sorted(p for p in (root/'lib-clean').rglob('*') if p.is_file())
files+=[root/'bin/native-authoring',*sorted(p for p in Path('.data/native-gerbil-canary-20261020').resolve().iterdir() if p.is_file()),*sorted(p for p in (root/'source/weaver-native').iterdir() if p.is_file())]
byteInputs={str(p):sha(p) for p in files}
link=json.loads((out/'link-public-load.json').read_text());assert link['exit']==0
reused=[]
for x in link['args']:
 p=Path(x)
 if x.endswith('.o') and p.is_file() and root not in p.parents:reused.append(dict(path=str(p),sha256=sha(p)))
gxi=Path(shutil.which('gxi')).resolve();prefix=gxi.parent.parent/'current';tools={str(p):sha(p) for p in [gxi,(prefix/'bin/gsc').resolve(),prefix/'bin/gambuild-C',Path('/opt/homebrew/bin/gcc-16').resolve()]}
for p in (prefix/'lib').glob('libgambit.*'):
 if p.is_file():tools[str(p)]=sha(p)
core=Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/core');pkg=core/'gerbil.pkg';snap=next(r for r in source['records'] if r['origin']==str(pkg));assert sha(pkg)==snap['sha256']
record=dict(modules=modules,sourceSnapshotRecords=len(source['records']),relatedSourceModules=39,isolatedLibraryFiles=len(list((root/'lib-clean').rglob('*'))),byteInputs=byteInputs,originalFixture=dict(path=str(original),sha256=sha(original)),reusedInstalledLinkObjects=reused,trustedToolsAndRuntime=tools,coreHead=source['coreHead'],pooPin=source['pooPin'],unchangedCorePackage=dict(path=str(pkg),sha256=sha(pkg)),linkReceipt='link-public-load.json',scope='Fresh isolated Core/POO/fixture/prelude sources; installed Gerbil/Gambit/std link objects explicitly reused; no full toolchain rebuild')
(out/'native-inputs-before.json').write_text(json.dumps(record,indent=2)+'\n');print('CAPTURED',len(modules),'source interfaces,',len(byteInputs),'stable inputs,',len(reused),'reused installed link objects')
