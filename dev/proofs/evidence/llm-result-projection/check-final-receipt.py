from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-result-projection'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==28 and all(c['exit']==0 for c in commands)
log=(out/'LlmResultProjection.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmResultProjection\.",log,re.M))==22
assert '41 passing' in (out/'tests.log').read_text()
assert '10 passing' in (out/'counterexamples.log').read_text()
assert '40 passing' in (out/'registry-regression.log').read_text()
for init in ['init','committed','sourceOnly','complete','pair','restarted','sent']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 105 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==14
assert len(json.loads((out/'counterexample-observations.json').read_text()))==10
assert len(json.loads((out/'source-receipt-check.json').read_text()))==33
assert len((out/'historical-manifests.log').read_text().splitlines())==25
assert len(json.loads((out/'diagram-validation.json').read_text()))==48
pins=''.join(hashlib.sha256((root/p).read_bytes()).hexdigest()+'  '+p+'\n' for p in ['devenv.lock','devenv.nix','devenv.yaml'])
assert pins==(root/'proofs/evidence/llm-semantic-contract/dependency-identity.log').read_text()
(out/'dependency-identity.log').write_text(pins)
identity=dict(repository=str(root),branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),scope='Design, formal sources and local evidence only; earlier workspace preserved')
assert identity['head']=='4df1f0233f9a78e5a3ea8a1a0d8aaca983698b8d'
(out/'checkout-identity.json').write_text(json.dumps(identity,indent=2)+'\n')
graph=[]
for c in commands:
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==17
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmResultProjection.lean','proofs/qunit/LlmResultProjection.qnt','proofs/check_llm_result_projection.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=28,leanModules=17,printedDeclarations=22,quintControls=41,guardedControls=31,counterexamples=10,parentRegressionControls=40,
 boundedSamples=70,maxPostInitializerSteps=30,seed=199,fourArtifactRows=14,englishOrgDocuments=105,d2Pairs=48,historicalManifestsUnchanged=25,
 freshlyVerifiedSourceBlobs=33,dependencyPinsChanged=False,gatewayImplementationChanged=False,aspCoreDependency=False,
 scope='Conditional committed typed results, ordered participant before/after CAS, closed mixed-prefix recovery and actual source-path composition',
 limitations=['Complete non-rollback result log and qualified source/result-prefix recovery remain explicit owner premises',
 'Typed exact bodies abstract native canonical bytes, cryptographic commitments and durable result blob availability',
 'Participant application is abstract atomic cursor/body CAS; no native fsync, storage engine, consensus or parser qualification',
 'Final broker fixture deduplicates operation IDs; earlier actual broker/range refinement is still required for transport',
 'Exposure never decreases; no settlement, cancellation, liveness, remote exactly-once, exhaustive model checking or performance claim',
 'Org export succeeded; optional htmlize fontification support is unavailable'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 28 routes; 22 Lean declarations; 41 Quint controls; ten decoded counterexamples; 70 bounded samples; pins unchanged')
