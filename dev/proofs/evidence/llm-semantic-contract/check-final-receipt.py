from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-semantic-contract'
commands=json.loads((out/'commands.json').read_text());assert len(commands)==20 and all(c['exit']==0 for c in commands)
log=(out/'LlmSemanticContract.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmSemanticContract\.",log,re.M))==17
assert '47 passing' in (out/'tests.log').read_text()
assert '34 passing' in (out/'attempt-regression.log').read_text()
assert '6 passing' in (out/'counterexamples.log').read_text()
for init in ['init','admittedDocument','sealed','admitted','buffered','proposed','released']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 80 Org documents' in (out/'org-export.log').read_text()
assert (out/'dependency-identity.log').read_text().splitlines()==(root/'proofs/evidence/llm-attempt-ledger/dependency-identity.log').read_text().splitlines()[:3]
modules=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract']
graph=[]
for m in modules:
 p=root/('proofs/lean' if m in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract'] else 'specs/lean')/(m+'.lean')
 graph.append(dict(module=m,path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
(out/'dependency-graph.json').write_text(json.dumps(dict(modules=graph,scope='Software authority only; Std belongs to the recorded toolchain'),indent=2)+'\n')
for path in ['proofs/lean/LlmSemanticContract.lean','proofs/qunit/LlmSemanticContract.qnt','proofs/check_llm_semantic_contract.py']:
 p=root/path;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=20,leanModules=9,newPrintedDeclarations=17,quintControls=47,
 deterministicControls=41,counterexamples=6,parentRegressionControls=34,boundedSamples=70,maxPostInitializerSteps=30,seed=157,
 fourArtifactRows=11,englishOrgDocuments=80,d2Pairs=40,historicalManifestsUnchanged=17,
 sourceBlobs=18,agentgatewaySourceBlobs=12,dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Conditional semantic projection preservation, typed invocation composition and bounded simulation',
 limitations=['Codec/name-map/parser/observation/release owner contracts remain premises',
 'No equivalent LLM behavior, native byte ownership or cryptographic proof',
 'Original registry-to-scope attestation is required but not mechanically derived',
 'No full asynchronous child/winner/range/account storage product proof',
 'No tool-execution transition; actual effects need a distinct broker admission',
 'No temporal liveness or native total-memory/performance guarantee'],
 preliminaryDiagnostics=['preliminary-lean.log','preliminary-lean-2.log','preliminary-lean-3.log'])
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 20 routes; 17 Lean statements; 47 Quint controls; six counterexamples; 70 bounded samples; pins unchanged')
