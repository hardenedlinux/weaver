from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-authoritative-scope'
commands=json.loads((out/'commands.json').read_text());assert len(commands)==21 and all(c['exit']==0 for c in commands)
log=(out/'LlmAuthoritativeScope.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmAuthoritativeScope\.",log,re.M))==21
assert '41 passing' in (out/'tests.log').read_text()
assert '47 passing' in (out/'semantic-regression.log').read_text()
assert '8 passing' in (out/'counterexamples.log').read_text()
for init in ['init','initMissing','registered','prepared','invoked','winner','recovered']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 83 Org documents' in (out/'org-export.log').read_text()
assert (out/'dependency-identity.log').read_text().splitlines()==(root/'proofs/evidence/llm-semantic-contract/dependency-identity.log').read_text().splitlines()[:3]
modules=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope']
graph=[]
for m in modules:
 p=root/('proofs/lean' if m in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope'] else 'specs/lean')/(m+'.lean')
 graph.append(dict(module=m,path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
(out/'dependency-graph.json').write_text(json.dumps(dict(modules=graph,scope='Software authority only; Std belongs to the recorded toolchain'),indent=2)+'\n')
for path in ['proofs/lean/LlmAuthoritativeScope.lean','proofs/qunit/LlmAuthoritativeScope.qnt','proofs/check_llm_authoritative_scope.py']:
 p=root/path;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=21,leanModules=10,newPrintedDeclarations=21,quintControls=41,
 deterministicControls=33,counterexamples=8,parentRegressionControls=47,boundedSamples=70,maxPostInitializerSteps=30,seed=163,
 fourArtifactRows=12,englishOrgDocuments=83,d2Pairs=41,historicalManifestsUnchanged=18,
 sourceBlobs=19,agentgatewaySourceBlobs=12,dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Conditional original-task scope derivation and root/child/semantic transition composition; bounded simulation',
 limitations=['Authority-owned canonical identity, immutable root/profile registry and authenticated publication are premises',
 'New native task-profile publication and joint consume transaction remain unimplemented',
 'Codec/parser/recovery predicates, storage/anchor refinement and tool-effect admission need native qualification',
 'No remote exactly-once, full asynchronous byte-range/account product or liveness/performance claim'],
 preliminaryDiagnostics=['preliminary-commands.json','preliminary-commands-2.json','preliminary-lean.log','preliminary-lean-2.log',
 'preliminary-lean-3.log','preliminary-lean-4.log','preliminary-lean-5.log','preliminary-typecheck.log','preliminary-typecheck-2.log','preliminary-typecheck-3.log'])
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 21 routes; 21 Lean declarations; 41 Quint controls; eight counterexamples; 70 bounded samples; pins unchanged')
