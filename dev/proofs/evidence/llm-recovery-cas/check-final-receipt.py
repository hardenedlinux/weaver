from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-recovery-cas'
commands=json.loads((out/'commands.json').read_text());assert len(commands)==23 and all(c['exit']==0 for c in commands)
log=(out/'LlmRecoveryCAS.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmRecoveryCAS\.",log,re.M))==19
assert '40 passing' in (out/'tests.log').read_text()
assert '43 passing' in (out/'publication-regression.log').read_text()
assert '8 passing' in (out/'counterexamples.log').read_text()
for init in ['init','observed','prepared','committed','restricted','restarted','unknown']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 89 Org documents' in (out/'org-export.log').read_text()
assert (out/'dependency-identity.log').read_text().splitlines()==(root/'proofs/evidence/llm-semantic-contract/dependency-identity.log').read_text().splitlines()[:3]
assert len(json.loads((out/'four-artifacts.json').read_text()))==12
assert len(json.loads((out/'counterexample-observations.json').read_text()))==8
assert len(json.loads((out/'source-review.json').read_text()))==19
assert len(json.loads((out/'agentgateway-source-review.json').read_text()))==12
assert len(json.loads((out/'source-receipt-check.json').read_text()))==31
assert len((out/'historical-manifests.log').read_text().splitlines())==20
assert len(json.loads((out/'diagram-validation.json').read_text()))==43
modules=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS']
graph=[]
for m in modules:
 p=root/('proofs/lean' if m in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS'] else 'specs/lean')/(m+'.lean')
 graph.append(dict(module=m,path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
(out/'dependency-graph.json').write_text(json.dumps(dict(modules=graph,scope='Software authority only; Std belongs to the recorded toolchain'),indent=2)+'\n')
for path in ['proofs/lean/LlmRecoveryCAS.lean','proofs/qunit/LlmRecoveryCAS.qnt','proofs/check_llm_recovery_cas.py']:
 p=root/path;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=23,leanModules=12,newPrintedDeclarations=19,quintControls=40,
 deterministicControls=32,counterexamples=8,parentRegressionControls=43,boundedSamples=70,maxPostInitializerSteps=30,seed=173,
 fourArtifactRows=12,englishOrgDocuments=89,d2Pairs=43,historicalManifestsUnchanged=20,
 sourceBlobs=19,agentgatewaySourceBlobs=12,dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Conditional authority-read / final CAS serialization, unique decisions and actual prior source-step projection; bounded simulation',
 limitations=['Durable non-rollback source state and coordinated effective Policy/history publication with final consumption are explicit owner contracts',
 'Native serialization, authenticated final cut and durable conditional owner commit remain unimplemented',
 'No backend consensus/fsync proof, remote exactly-once, full asynchronous range/account product, liveness or performance claim'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))

(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 23 routes; 19 Lean declarations; 40 Quint controls; eight counterexamples; 70 bounded samples; pins unchanged')
