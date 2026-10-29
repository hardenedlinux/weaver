from pathlib import Path
import hashlib,json,subprocess,shutil
out=Path(__file__).parent;core=Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/core');lib=core/'.gerbil/lib'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
paths=[]
for module in ['core/modules/json-schema/contracts','core/modules/json-schema/json-schema-source','clan/poo/object','clan/poo/mop']:
 p=lib/module
 paths.extend(sorted(p.parent.glob(p.name+'.*')))
paths=[p for p in paths if p.is_file()]
assert paths
artifacts={str(p):sha(p) for p in paths}
native=json.loads((out/'native-authoring.json').read_text());assert native['exit'] in (0,124)
log=(out/'native-authoring.log').read_text();checks=[line for line in log.splitlines() if line.startswith('CHECK ')]
assert len(checks)==11 and all(line.endswith(' PASS') for line in checks)
assert 'OBSERVATION duplicate-json-contract-accepted decoder-rejected' in log
assert 'NATIVE-AUTHORING-CHECKS-COMPLETE' in log
binary=Path(shutil.which('gxi')).resolve();runtime=(out/'version-only.log').read_text().splitlines()[0]
sourceRows=[]
for name in ['modules/json-schema/contracts.ss','modules/json-schema/json-schema-source.ss','modules/json-schema/json-schema-constraints.ss','gerbil.pkg']:
 p=core/name
 blob=subprocess.check_output(['git','-C',str(core),'show','HEAD:'+name]);sourceRows.append(dict(path=str(p),sha256=sha(p),headSha256=hashlib.sha256(blob).hexdigest(),workingEqualsHead=p.read_bytes()==blob))
stdlib=binary.parent.parent/'1cfb032/src/std/encoding/json/reader.ss';assert stdlib.exists()
result=dict(status='ASSERTIONS_COMPLETE_NATURAL_EXIT_TIMEOUT',nativeContractChecks=11,duplicateKeyDecoderRejection=True,runtime=runtime,binary=str(binary),binarySha256=sha(binary),coreHead=subprocess.check_output(['git','-C',str(core),'rev-parse','HEAD'],text=True).strip(),compiledArtifactsObservedAfterRun=artifacts,artifactBoundary='Selected directly referenced interfaces/artifacts observed after the run; not a before/after stability receipt or exhaustive loaded dependency closure',sources=sourceRows,installedJsonReader=dict(path=str(stdlib),sha256=sha(stdlib)),observedProcessExit=native['exit'],nativeQualification=False,currentSourceBuildQualified=False,yamlExecuted=False,gatewayNormalizerImplemented=False)
(out/'native-identity.json').write_text(json.dumps(result,indent=2)+'\n');print('RECORDED: 11 native check outputs and duplicate-key rejection; natural exit timed out; qualification remains open')
