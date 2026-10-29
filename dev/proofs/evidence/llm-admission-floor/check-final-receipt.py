from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-admission-floor'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==39 and all(c['exit']==0 for c in commands)
for c in commands:
 assert c['sourceSha256'],c['label']
 for p,digest in c['sourceSha256'].items():assert hashlib.sha256((root/p).read_bytes()).hexdigest()==digest,(c['label'],p)
log=(out/'LlmAdmissionFloor.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmAdmissionFloor\.",log,re.M))==14
assert '71 passing' in (out/'tests.log').read_text()
assert '8 passing' in (out/'counterexamples.log').read_text()
assert '77 passing' in (out/'handoff-regression.log').read_text()
for init in ['init','qualifiedInit','proposed','published','recovered','sealed','rotated','ownerRecovered','lateCommitted']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 132 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==14
assert len(json.loads((out/'counterexample-observations.json').read_text()))==8
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==34
assert len(json.loads((out/'diagram-validation.json').read_text()))==57
live=json.loads((out/'working-source-check.json').read_text())
assert len(live)==19 and sum(r['sameWorkingBytes'] for r in live)==18
check=subprocess.run(['python3',str(out/'check-working-sources.py')],capture_output=True,text=True,timeout=20)
(out/'working-source-check.log').write_text(check.stdout+check.stderr)
assert check.returncode==0,check.stdout+check.stderr
pins=''.join(hashlib.sha256((root/p).read_bytes()).hexdigest()+'  '+p+'\n' for p in ['devenv.lock','devenv.nix','devenv.yaml'])
assert pins==(root/'proofs/evidence/llm-semantic-contract/dependency-identity.log').read_text()
(out/'dependency-identity.log').write_text(pins)
identity=dict(repository=str(root),branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),scope='Design, formal sources and local evidence only; earlier workspace preserved')
assert identity['head']=='4df1f0233f9a78e5a3ea8a1a0d8aaca983698b8d'
(out/'checkout-identity.json').write_text(json.dumps(identity,indent=2)+'\n')
graph=[]
for c in commands:
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff','LlmAdmissionFloor']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==26
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmAdmissionFloor.lean','proofs/qunit/LlmAdmissionFloor.qnt','proofs/check_llm_admission_floor.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=39,leanModules=26,printedDeclarations=14,
 quintControls=71,newControls=33,guardedNewControls=25,directlyImportedHandoffControls=38,counterexamples=8,parentRegressionControls=77,
 boundedSamples=90,maxPostInitializerSteps=30,seed=257,fourArtifactRows=14,englishOrgDocuments=132,d2Pairs=57,historicalManifestsUnchanged=34,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,
 workingSourceDrift='P17: two control-plane import paths only; new import targets native ABI not qualified',
 dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Independent determining admission prefix, original-result/current-head separation, exact recovery image/body/owner qualification and actual handoff/account/source composition',
 limitations=['Qualified durable single prefix, authenticated current reads, namespace bootstrap and body/archive independence are native premises; no new consensus or quorum implementation is proved',
 'Local metadata and object rollback cannot install financial authority; original source/account/Policy/history and final broker/executor gates remain mandatory',
 'Actual handoff includes source/account readiness; native cross-store bridge and effect-time serialization are not derived from floor-parent equality',
 'Native canonical operation/intent encoding and Host authentication are required; equal numeric tags do not authenticate the original request',
 'Pending intents and committed floor/archive history are retained; no expiry, compaction or bounded cleanup/liveness proof',
 'One unresolved cut and one uncommitted settlement frame per account lane remain inherited restrictions',
 'Lean captures actual source generation; bounded Quint fixture keeps source generation fixed',
 'Unknown-source hold theorem requires inherited original-key binding for every commit path; finite pending hold is independently decoded',
 'Protected-prefix rollback mutation relies on retained reference history and does not prove co-restored authorities independent',
 'No native IO/ABI/codec/consensus qualification, arbitrary-account product, provider exactly-once delivery, exhaustive exploration or performance claim',
 'Optional htmlize fontification unavailable during successful Org export'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 39 routes; 14 Lean declarations; 33 new plus 38 imported controls; eight decoded violations; 90 samples; pins unchanged')
