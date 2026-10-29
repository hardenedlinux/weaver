from pathlib import Path
import subprocess,json,hashlib
root=Path('.data/native-gerbil-exit-20261020').resolve();out=Path(__file__).parent;source=root/'source';source.mkdir(exist_ok=True)
core=Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/core');poo=Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/.gerbil/pkg/github.com/tao3k/gerbil-poo');pin='fdeadfa40ca5cee5fe20308985aef1577f2eb49b';assert pin in (core/'gerbil.pkg').read_text();assert subprocess.check_output(['git','-C',str(poo),'rev-parse','HEAD'],text=True).strip()==pin
records=[]
def save(target,data,origin):
 target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);records.append(dict(snapshot=str(target),origin=origin,sha256=hashlib.sha256(data).hexdigest()))
excluded={'.git','.gerbil','.data','docs','proofs','node_modules'}
paths=sorted(p for p in core.rglob('*') if p.is_file() and not (excluded & set(p.relative_to(core).parts)) and (p.suffix in ('.ss','.scm','.json') or p.name=='gerbil.pkg'))
for p in paths:save(source/'core'/p.relative_to(core),p.read_bytes(),str(p))
for name in subprocess.check_output(['git','-C',str(poo),'ls-tree','-r','--name-only',pin],text=True).splitlines():
 if name.endswith(('.ss','.scm')) or name.endswith('gerbil.pkg'):
  save(source/'clan/poo'/name,subprocess.check_output(['git','-C',str(poo),'show',pin+':'+name]),str(poo)+':'+pin+':'+name)
fixture=Path('proofs/evidence/committed-profile-binding/native-authoring.ss');save(source/'weaver-native/fixture.ss',fixture.read_bytes(),str(fixture))
(source/'weaver-native/gerbil.pkg').write_text('(package: weaver-native)\n')
result=dict(root=str(root),coreHead=subprocess.check_output(['git','-C',str(core),'rev-parse','HEAD'],text=True).strip(),pooPin=pin,records=records,policy='Core JSON-schema source working bytes; POO exactly existing pin; no installed artifact copied into isolated output')
(out/'source-snapshot.json').write_text(json.dumps(result,indent=2)+'\n');print('snapshot',len(records),'files',root)
