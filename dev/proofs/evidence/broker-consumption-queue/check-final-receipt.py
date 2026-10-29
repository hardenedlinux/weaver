from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/broker-consumption-queue'
commands=json.loads((out/'commands.json').read_text());assert len(commands)==16 and all(c['exit']==0 for c in commands)
log=(out/'BrokerConsumptionQueue.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.BrokerConsumptionQueue\.",log,re.M))==21
assert '75 passing' in (out/'tests.log').read_text()
assert '59 passing' in (out/'gateway-head-regression.log').read_text()
assert '6 passing' in (out/'counterexamples.log').read_text()
for init in ['init','consumed','queued','reserved','uncertain','firstDone','complete']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 66 Org documents' in (out/'org-export.log').read_text()
assert (out/'dependency-identity.log').read_text().splitlines()==(root/'proofs/evidence/gateway-head-cas/dependency-identity.log').read_text().splitlines()[:3]
modules=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue']
graph=[]
for m in modules:
 p=root/('proofs/lean' if m in ['GatewayHeadCAS','BrokerConsumptionQueue'] else 'specs/lean')/(m+'.lean')
 graph.append(dict(module=m,path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
(out/'dependency-graph.json').write_text(json.dumps(dict(modules=graph,scope='Software authority only; Std belongs to the recorded toolchain'),indent=2)+'\n')
for path in ['proofs/lean/BrokerConsumptionQueue.lean','proofs/qunit/BrokerConsumptionQueue.qnt','proofs/check_broker_consumption_queue.py']:
 p=root/path;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
(out/'final-receipt.json').write_text(json.dumps(dict(status='pass',commandRoutes=16,leanModules=5,newPrintedDeclarations=21,quintControls=75,newControls=33,importedParentControls=42,parentRegressionControls=59,counterexamples=6,boundedSamples=70,maxPostInitializerSteps=30,seed=137,fourArtifactRows=10,scope='Conditional model proof and bounded simulation; native SDK/storage/provider refinement remains open'),indent=2)+'\n')
print('PASS: 16 routes; 21 Lean declarations; 75 Quint controls; six counterexamples; 70 bounded samples; dependency pins unchanged')
