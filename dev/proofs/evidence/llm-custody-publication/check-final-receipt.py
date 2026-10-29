from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-custody-publication'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==43 and all(c['exit']==0 for c in commands)
for c in commands:
 assert c['sourceSha256'],c['label']
 for p,digest in c['sourceSha256'].items():assert hashlib.sha256((root/p).read_bytes()).hexdigest()==digest,(c['label'],p)
log=(out/'LlmCustodyPublication.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmCustodyPublication\.",log,re.M))==15
assert '25 passing' in (out/'tests.log').read_text()
assert '7 passing' in (out/'counterexamples.log').read_text()
assert '23 passing' in (out/'custody-regression.log').read_text()
for init in ['boot','stagedFloor','committed','handed','recovered','restored','exactCopyRestored','restarted','finished']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 141 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==15
assert len(json.loads((out/'counterexample-observations.json').read_text()))==7
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==37
assert len(json.loads((out/'diagram-validation.json').read_text()))==60
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
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff','LlmAdmissionFloor','LlmSourceJoin','LlmSourceCustody','LlmCustodyPublication']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==29
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmCustodyPublication.lean','proofs/qunit/LlmCustodyPublication.qnt','proofs/check_llm_custody_publication.py','proofs/prepare_llm_publication_closure.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
closure=subprocess.run(['python3',str(out/'check-closure-certificate.py')],capture_output=True,text=True,timeout=20)
(out/'closure-check.log').write_text(closure.stdout+closure.stderr);assert closure.returncode==0,closure.stdout+closure.stderr
receipt=dict(status='pass',commandRoutes=43,leanModules=29,printedDeclarations=15,
 quintControls=25,guardedNewControls=18,counterexamples=7,parentRegressionControls=23,
 boundedSamples=90,maxPostInitializerSteps=30,seed=277,fourArtifactRows=15,
 englishOrgDocuments=141,d2Pairs=60,historicalManifestsUnchanged=37,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,
 workingSourceDrift='P17: two control-plane import paths only; native ABI not qualified',
 quintClosureModules=10,retainedCurrentAndParentControls=48,omittedTransitiveRunDeclarations=308,
 quintClosure='Retained declaration IR identical; current and parent model bytes identical; only unrelated transitive run spans blanked. Original full-import typecheck timeout retained.',
 leanEvidenceResumedAfterInputHashVerification=True,incrementalLeafAtomicTheoremRecheck=True,dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='One protected custody/floor journal, current authority-parent publication, original-outcome retention across projection recovery, actual initialized custody/join/floor/account composition',
 limitations=['Whole-event atomic durable append and authenticated current protected prefix remain native owner contracts; no storage or consensus implementation is proved',
 'Per-component persistence callbacks in logicalOwner are pure semantics; native publication must supply original intent/arm/fence/outcome durability together',
 'Authenticated caller incarnation/custody capability and authorized publication remain native premises; numeric tuple equality is not caller authentication',
 'Arbitrary restoration affects untrusted projections only; authoritative journal or account-store rollback is not admitted as a safe model transition',
 'Lean takes an explicit initialized actual custody prefix; finite Quint starts from the unchanged prior armed initializer',
 'Compact Quint entries capture fence/intent/outcome/floor while inherited custody phases and joins remain active; no automatic Quint-to-Lean or native refinement is claimed',
 'Actual original source/reservation binding and Safe initialized account prefix are required by the budget composition',
 'Qualification-marker mutations demonstrate invalid protocol transitions, not an external send or native co-rollback detector',
 'Actual split-write and old-worker controls invoke inherited custody/floor transitions; provider execution and the original pending hold are independently checked unchanged',
 'The generated closure omits 308 older transitive tests, not types or transitions; those historical tests are not claimed rerun in this acceptance',
 'No journal GC, arbitrary namespace/account product, recovery fairness/liveness, provider exactly-once, native IO/ABI/codec qualification or performance claim',
 'Optional htmlize fontification unavailable during successful Org export'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 43 routes; 29 Lean modules and 15 declarations; 25 new and 23 parent controls; seven decoded violations; 90 samples; certified closure; pins unchanged')
