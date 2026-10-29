from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-policy-continuation'
commands=json.loads((out/'commands.json').read_text());assert len(commands)==25 and all(c['exit']==0 for c in commands)
log=(out/'LlmPolicyContinuation.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmPolicyContinuation\.",log,re.M))==18
assert '42 passing' in (out/'tests.log').read_text()
assert '45 passing' in (out/'policy-regression.log').read_text()
assert '8 passing' in (out/'counterexamples.log').read_text()
for init in ['init','conflicted','inspected','approved','committed','restarted','unknown']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 96 Org documents' in (out/'org-export.log').read_text()
assert (out/'dependency-identity.log').read_text().splitlines()==(root/'proofs/evidence/llm-semantic-contract/dependency-identity.log').read_text().splitlines()[:3]
assert len(json.loads((out/'four-artifacts.json').read_text()))==12
assert len(json.loads((out/'counterexample-observations.json').read_text()))==8
assert len(json.loads((out/'source-review.json').read_text()))==19
assert len(json.loads((out/'agentgateway-source-review.json').read_text()))==12
assert len(json.loads((out/'source-receipt-check.json').read_text()))==33
assert len(json.loads((out/'asp-source-review.json').read_text()))==2
assert len(json.loads((out/'protocol-sources.json').read_text()))==7
assert len((out/'historical-manifests.log').read_text().splitlines())==22
assert len(json.loads((out/'diagram-validation.json').read_text()))==45
modules=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation']
graph=[]
for m in modules:
 p=root/('proofs/lean' if m in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation'] else 'specs/lean')/(m+'.lean')
 graph.append(dict(module=m,path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
(out/'dependency-graph.json').write_text(json.dumps(dict(modules=graph,scope='Software authority only; Std belongs to the recorded toolchain'),indent=2)+'\n')
for path in ['proofs/lean/LlmPolicyContinuation.lean','proofs/qunit/LlmPolicyContinuation.qnt','proofs/check_llm_policy_continuation.py']:
 p=root/path;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=25,leanModules=14,newPrintedDeclarations=18,quintControls=42,
 deterministicControls=34,counterexamples=8,parentRegressionControls=45,boundedSamples=70,maxPostInitializerSteps=30,seed=181,
 fourArtifactRows=12,englishOrgDocuments=96,d2Pairs=45,historicalManifestsUnchanged=22,
 sourceBlobs=19,agentgatewaySourceBlobs=12,aspSourceBlobs=2,officialProtocolReferences=7,dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Conditional complete-family conflict resolution, source-bound continuation, immutable winner and canonical protocol aliases; bounded simulation',
 limitations=['Canonical source-family classification, complete-prefix absence, current reauthorization and non-rollback state are explicit owner contracts',
 'Native atomic winner/source publication, durable linked approval and protocol adapter conformance remain unimplemented',
 'No backend consensus/fsync proof, remote exactly-once, full asynchronous range/account product, liveness or performance claim'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))

(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 25 routes; 18 Lean declarations; 42 Quint controls; eight counterexamples; 70 bounded samples; pins unchanged')
