from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-caller-custody';docs=root/'docs/40-49-admission-coordination/43-caller-custody'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==43
assert all(r['exit']==0 or (r['label']=='typecheck' and r['exit']==124 and r['watchdogSeconds']==20) for r in commands)
timeouts=[r for r in commands if r['exit']==124]
assert len(timeouts)<=1
pipeline=json.loads((out/'quint-test-pipeline.json').read_text())
assert hashlib.sha256(Path(pipeline['path']).read_bytes()).hexdigest()==pipeline['sha256']
assert Path(pipeline['path']).read_text().splitlines()[pipeline['line']-1]==pipeline['text']
assert '.then(chainCmd(cliCommands_1.typecheck)).then(chainCmd(cliCommands_1.runTests))' in pipeline['text']
for r in commands:
 assert r['seconds']<=r['watchdogSeconds']+1
 for p,digest in r['sourceSha256'].items():assert hashlib.sha256((root/p).read_bytes()).hexdigest()==digest,(r['label'],p)
 assert (out/(r['label']+'.log')).is_file()
lean=(out/'LlmCallerCustody.log').read_text();assert 'sorryAx' not in lean and 'error:' not in lean
assert len(re.findall(r"^'Weaver.LlmCallerCustody\.",lean,re.M))==22
assert '27 passing' in (out/'tests.log').read_text()
assert '7 passing' in (out/'counterexamples.log').read_text()
assert '25 passing' in (out/'publication-regression.log').read_text()
for name in ['boot','staged','committed','handed','recovered','rotated','restarted','expired']:
 assert '[ok] No violation found' in (out/(name+'.log')).read_text(),name
for n in ['check-source-receipts.py','check-working-sources.py','check-closure-certificate.py','check-four-artifacts.py','check-counterexample-observations.py']:
 p=subprocess.run(['python3',str(out/n)],capture_output=True,text=True,timeout=20)
 (out/(n.replace('.py','.log'))).write_text(p.stdout+p.stderr);assert p.returncode==0,p.stdout+p.stderr
pins=[]
for n in ['devenv.lock','devenv.nix','devenv.yaml','.envrc','proofs/evidence/llm-semantic-contract/dependency-identity.log']:
 p=root/n;pins.append(dict(path=n,sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
# The unchanged earlier byte manifests contain dependency-identity.log and pin bytes.
for p in list((root/'specs/evidence').glob('*/SHA256SUMS'))+list((root/'proofs/evidence').glob('*/SHA256SUMS')):
 if p.parent==out:continue
 for row in p.read_text().splitlines():
  digest,name=row.split('  ',1);assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,(p,name)
assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()=='4df1f0233f9a78e5a3ea8a1a0d8aaca983698b8d'
for source in ['proofs/lean/LlmCallerCustody.lean','proofs/qunit/LlmCallerCustody.qnt','proofs/check_llm_caller_custody.py','proofs/prepare_llm_caller_closure.py']:
 (out/Path(source).name).write_bytes((root/source).read_bytes())
receipt=dict(status='SEMANTIC_CHECKS_PASS_RESOURCE_GATE_FAILED' if timeouts else 'PASS',standaloneTypecheck='TIMEOUT_20S_NOT_PASSED' if timeouts else 'PASS',successfulRoutes=len(commands)-len(timeouts),timeoutRoutes=len(timeouts),typingEvidence='Official installed test pipeline performs typecheck before runTests; standalone timeout remains failed',scope='Executable design models and English Org / core D2; no Gateway runtime implementation',routes=len(commands),leanModules=30,printedDeclarations=22,newQuintControls=27,parentPublicationControls=25,exportedMutations=7,randomInitializers=8,randomSamples=80,maxPostInitSteps=30,seed=283,sourceFiles=19,workingSourceExactMatches=18,originalHold12=2,providerCallsInCounterexamples=0,englishOrgDocuments=144,coreDiagramPairs=61,historicalManifests=38,fourArtifactRows=22,pins=pins,premises=['Authentic native peer and request-bound key proof','Trusted enrollment and independent recovery authorization','One protected whole-event append including current grant and custody outcome','Nondecreasing trusted time across recovery','Canonical original semantic and reservation/source binding','Initialized actual publication/custody/account prefix and Safe handoff'],notQualified=['Native authentication/PoP implementation','Kubernetes RBAC and enrollment deployment','Native durability and anti-rollback','Quint-to-Lean or model-to-runtime automatic refinement','Recovery liveness','Provider IO exactly-once or performance'])
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('Semantic checks passed; standalone typecheck status recorded without reclassification. 43 routes; 30 Lean modules / 22 declarations; 27+25 Quint controls; 7 decoded mutations; 80 bounded samples; native premises explicit')
