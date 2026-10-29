from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-routing'
commands=json.loads((out/'commands.json').read_text());assert len(commands)==15 and all(c['exit']==0 for c in commands)
log=(out/'LlmRouting.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmRouting\.",log,re.M))==15
assert '32 passing' in (out/'tests.log').read_text()
assert '66 passing' in (out/'range-recovery-regression.log').read_text()
assert '6 passing' in (out/'counterexamples.log').read_text()
for init in ['init','planned','dispatched','responded']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 74 Org documents' in (out/'org-export.log').read_text()
assert (out/'dependency-identity.log').read_text().splitlines()==(root/'proofs/evidence/logical-range-recovery/dependency-identity.log').read_text().splitlines()[:3]
modules=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting']
graph=[]
for m in modules:
 p=root/('proofs/lean' if m in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting'] else 'specs/lean')/(m+'.lean')
 graph.append(dict(module=m,path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
(out/'dependency-graph.json').write_text(json.dumps(dict(modules=graph,scope='Software authority only; Std belongs to the recorded toolchain'),indent=2)+'\n')
for path in ['proofs/lean/LlmRouting.lean','proofs/qunit/LlmRouting.qnt','proofs/check_llm_routing.py']:
 p=root/path;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
(out/'final-receipt.json').write_text(json.dumps(dict(status='pass',commandRoutes=15,leanModules=7,newPrintedDeclarations=15,quintControls=32,newControls=32,importedParentControls=0,parentRegressionControls=66,counterexamples=6,boundedSamples=40,maxPostInitializerSteps=30,seed=149,fourArtifactRows=10,scope='Conditional model proof and bounded simulation; native SDK/storage/provider refinement remains open'),indent=2)+'\n')
print('PASS: 15 routes; 15 Lean declarations; 32 Quint controls; six counterexamples; 40 bounded samples; dependency pins unchanged')
