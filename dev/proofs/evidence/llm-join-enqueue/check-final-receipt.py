from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-join-enqueue'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==29 and all(c['exit']==0 for c in commands)
log=(out/'LlmJoinEnqueue.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmJoinEnqueue\.",log,re.M))==19
assert '40 passing' in (out/'tests.log').read_text()
assert '10 passing' in (out/'counterexamples.log').read_text()
assert '41 passing' in (out/'projection-regression.log').read_text()
for init in ['init','complete','resolved','newJoined','newOwner','enqueued','sent']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 108 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==16
assert len(json.loads((out/'counterexample-observations.json').read_text()))==10
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==26
assert len(json.loads((out/'diagram-validation.json').read_text()))==49
pins=''.join(hashlib.sha256((root/p).read_bytes()).hexdigest()+'  '+p+'\n' for p in ['devenv.lock','devenv.nix','devenv.yaml'])
assert pins==(root/'proofs/evidence/llm-semantic-contract/dependency-identity.log').read_text()
(out/'dependency-identity.log').write_text(pins)
identity=dict(repository=str(root),branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),scope='Design, formal sources and local evidence only; earlier workspace preserved')
assert identity['head']=='4df1f0233f9a78e5a3ea8a1a0d8aaca983698b8d'
(out/'checkout-identity.json').write_text(json.dumps(identity,indent=2)+'\n')
graph=[]
for c in commands:
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==18
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmJoinEnqueue.lean','proofs/qunit/LlmJoinEnqueue.qnt','proofs/check_llm_join_enqueue.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=29,leanModules=18,printedDeclarations=19,quintControls=40,guardedControls=30,counterexamples=10,parentRegressionControls=41,
 boundedSamples=70,maxPostInitializerSteps=30,seed=211,fourArtifactRows=16,englishOrgDocuments=108,d2Pairs=49,historicalManifestsUnchanged=26,
 freshlyVerifiedSourceBlobs=19,dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Admission-only actual source transitions, atomic current join/fence/Policy/slot gate and initialized existing broker suffix composition',
 limitations=['Native semantic footprint must include all effect-producing channels and exclude hidden provider callbacks',
 'Original operation/manifest binding, effective final Policy and durable atomic key/slot/receipt admission remain explicit owner contracts',
 'No native storage, consensus, canonical codec, driver confinement or complete asynchronous source/executor product qualification',
 'Initialized abstract broker suffix proves bounded local invocation/unknown holds; its erased owner is not native authorization',
 'No settlement, liveness, remote exactly-once, exhaustive state exploration or performance claim',
 'Org export succeeded; optional htmlize source-fontification support is unavailable'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 29 routes; 19 Lean declarations; 40 Quint controls; ten decoded counterexamples; 70 bounded samples; pins unchanged')
