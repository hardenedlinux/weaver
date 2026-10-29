from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-executor-offer'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==30 and all(c['exit']==0 for c in commands)
log=(out/'LlmExecutorOffer.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmExecutorOffer\.",log,re.M))==20
assert '42 passing' in (out/'tests.log').read_text()
assert '10 passing' in (out/'counterexamples.log').read_text()
assert '40 passing' in (out/'enqueue-regression.log').read_text()
for init in ['init','enqueued','observed','burned','offered','partialWrite','realigned']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 111 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==18
assert len(json.loads((out/'counterexample-observations.json').read_text()))==10
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==27
assert len(json.loads((out/'diagram-validation.json').read_text()))==50
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
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==19
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmExecutorOffer.lean','proofs/qunit/LlmExecutorOffer.qnt','proofs/check_llm_executor_offer.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=30,leanModules=19,printedDeclarations=20,quintControls=42,guardedControls=32,counterexamples=10,parentRegressionControls=40,
 boundedSamples=70,maxPostInitializerSteps=30,seed=223,fourArtifactRows=18,englishOrgDocuments=111,d2Pairs=50,historicalManifestsUnchanged=27,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,workingSourceDrift="P17: two control-plane import paths only; ABI equivalence not qualified",dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Actual admission/logical-range product, qualified executor recovery, current burn/offer gate and initialized broker projection',
 limitations=['Native affine durable handoff, non-rollback dispatch prefix and exclusive final writer remain qualification premises',
 'Original effect binding, complete reserve/offer Policy context, receipt consistency and state-aware cross-ledger background checks remain explicit owner contracts',
 'Source zero-call counters are not no-execution evidence; full native source/executor/settlement/account alignment is not implemented',
 'Selected admitted interval; no automatic partial-tail retry, uncertain-burn reclamation or recovery liveness',
 'Possible-offer records may conservatively cover zero physical bytes; no wall-clock zero-byte-after-revocation or remote exactly-once claim',
 'No native storage, codec, transport instrumentation, exhaustive model checking or performance qualification',
 'Org export succeeded; optional htmlize source-fontification support is unavailable'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 30 routes; 20 Lean declarations; 42 Quint controls; ten decoded counterexamples; 70 bounded samples; pins unchanged')
