from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-registry-publication'
commands=json.loads((out/'commands.json').read_text());assert len(commands)==22 and all(c['exit']==0 for c in commands)
log=(out/'LlmRegistryPublication.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmRegistryPublication\.",log,re.M))==20
assert '43 passing' in (out/'tests.log').read_text()
assert '41 passing' in (out/'authority-regression.log').read_text()
assert '8 passing' in (out/'counterexamples.log').read_text()
for init in ['init','pending','committed','certified','activated','invoked','recovered']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 86 Org documents' in (out/'org-export.log').read_text()
assert (out/'dependency-identity.log').read_text().splitlines()==(root/'proofs/evidence/llm-semantic-contract/dependency-identity.log').read_text().splitlines()[:3]
assert len(json.loads((out/'four-artifacts.json').read_text()))==12
assert len(json.loads((out/'counterexample-observations.json').read_text()))==8
assert len(json.loads((out/'source-review.json').read_text()))==19
assert len(json.loads((out/'agentgateway-source-review.json').read_text()))==12
assert len(json.loads((out/'source-receipt-check.json').read_text()))==31
assert len((out/'historical-manifests.log').read_text().splitlines())==19
assert len(json.loads((out/'diagram-validation.json').read_text()))==42
modules=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication']
graph=[]
for m in modules:
 p=root/('proofs/lean' if m in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication'] else 'specs/lean')/(m+'.lean')
 graph.append(dict(module=m,path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
(out/'dependency-graph.json').write_text(json.dumps(dict(modules=graph,scope='Software authority only; Std belongs to the recorded toolchain'),indent=2)+'\n')
for path in ['proofs/lean/LlmRegistryPublication.lean','proofs/qunit/LlmRegistryPublication.qnt','proofs/check_llm_registry_publication.py']:
 p=root/path;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=22,leanModules=11,newPrintedDeclarations=20,quintControls=43,
 deterministicControls=35,counterexamples=8,parentRegressionControls=41,boundedSamples=70,maxPostInitializerSteps=30,seed=167,
 fourArtifactRows=12,englishOrgDocuments=86,d2Pairs=42,historicalManifestsUnchanged=19,
 sourceBlobs=19,agentgatewaySourceBlobs=12,dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Conditional sticky registry publication, exact current recovery join and actual prior execution-step projection; bounded simulation',
 limitations=['Independent non-rollback intent/fence, durable journal, immutable object and current execution-prefix reads are explicit owner contracts',
 'Native original claim/profile publication, cross-store recovery and final conditional consumption remain unimplemented',
 'No backend consensus/fsync proof, remote exactly-once, full asynchronous range/account product, liveness or performance claim'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))

(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 22 routes; 20 Lean declarations; 43 Quint controls; eight counterexamples; 70 bounded samples; pins unchanged')
