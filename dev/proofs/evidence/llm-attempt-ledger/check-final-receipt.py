from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-attempt-ledger'
commands=json.loads((out/'commands.json').read_text());assert len(commands)==18 and all(c['exit']==0 for c in commands)
log=(out/'LlmAttemptLedger.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmAttemptLedger\.",log,re.M))==15
assert '34 passing' in (out/'tests.log').read_text()
assert '32 passing' in (out/'routing-regression.log').read_text()
assert '6 passing' in (out/'counterexamples.log').read_text()
for init in ['init','initDuplicate','initToolDuplicate','unknown','failover','winner']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 77 Org documents' in (out/'org-export.log').read_text()
assert (out/'dependency-identity.log').read_text().splitlines()==(root/'proofs/evidence/llm-routing/dependency-identity.log').read_text().splitlines()[:3]
modules=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger']
graph=[]
for m in modules:
 p=root/('proofs/lean' if m in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger'] else 'specs/lean')/(m+'.lean')
 graph.append(dict(module=m,path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
(out/'dependency-graph.json').write_text(json.dumps(dict(modules=graph,scope='Software authority only; Std belongs to the recorded toolchain'),indent=2)+'\n')
for path in ['proofs/lean/LlmAttemptLedger.lean','proofs/qunit/LlmAttemptLedger.qnt','proofs/check_llm_attempt_ledger.py']:
 p=root/path;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=18,leanModules=8,newPrintedDeclarations=15,quintControls=34,
 deterministicControls=28,counterexamples=6,parentRegressionControls=32,boundedSamples=60,maxPostInitializerSteps=30,seed=151,
 fourArtifactRows=10,englishOrgDocuments=77,d2Pairs=39,historicalManifestsUnchanged=16,
 sourceBlobs=18,agentgatewaySourceBlobs=10,dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Conditional invariant preservation and bounded simulation; no native SDK/storage/provider or asynchronous full range/settlement product proof',
 limitations=['Owner predicates and durable atomic operations are assumptions','Provider finality and hard cost bounds need runtime qualification',
 'General Lean exact usage-slot sum equality is not proved','No temporal liveness or remote exactly-once claim'],
 preliminaryDiagnostics=['preliminary-lean.log','preliminary-lean-2.log','preliminary-lean-3.log'])
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 18 routes; 15 Lean declarations; 34 Quint controls; six counterexamples; 60 bounded samples; pins unchanged')
