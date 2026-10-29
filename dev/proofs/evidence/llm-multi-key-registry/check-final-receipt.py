from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-multi-key-registry'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==27 and all(c['exit']==0 for c in commands)
log=(out/'LlmMultiKeyRegistry.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmMultiKeyRegistry\.",log,re.M))==24
assert '40 passing' in (out/'tests.log').read_text()
assert '10 passing' in (out/'counterexamples.log').read_text()
assert '49 passing' in (out/'registry-regression.log').read_text()
for init in ['init','registered','pair','aliases','unknown','restarted','stagedRace']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 102 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==14
assert len(json.loads((out/'counterexample-observations.json').read_text()))==10
assert len(json.loads((out/'source-receipt-check.json').read_text()))==33
assert len((out/'historical-manifests.log').read_text().splitlines())==24
assert len(json.loads((out/'diagram-validation.json').read_text()))==47
pins=''.join(hashlib.sha256((root/p).read_bytes()).hexdigest()+'  '+p+'\n' for p in ['devenv.lock','devenv.nix','devenv.yaml'])
assert pins==(root/'proofs/evidence/llm-semantic-contract/dependency-identity.log').read_text()
(out/'dependency-identity.log').write_text(pins)
identity=dict(repository=str(root),branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),scope='Design, formal sources and local evidence only; earlier workspace preserved')
assert identity['head']=='4df1f0233f9a78e5a3ea8a1a0d8aaca983698b8d'
(out/'checkout-identity.json').write_text(json.dumps(identity,indent=2)+'\n')
graph=[]
for c in commands:
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==16
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmMultiKeyRegistry.lean','proofs/qunit/LlmMultiKeyRegistry.qnt','proofs/check_llm_multi_key_registry.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=27,leanModules=16,printedDeclarations=24,quintControls=40,guardedControls=30,counterexamples=10,parentRegressionControls=49,
 boundedSamples=70,maxPostInitializerSteps=30,seed=197,fourArtifactRows=14,englishOrgDocuments=102,d2Pairs=47,historicalManifestsUnchanged=24,
 freshlyVerifiedSourceBlobs=33,dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Conditional multi-key registry/source serialization, arbitrary finite authority runs, shared exposure bound and actual prior-source refinement',
 limitations=['Admitted canonical identity, exact source-step refinement and qualified non-rollback recovery remain explicit premises',
 'No native journal barrier, participant position/result CAS, consensus, disk reconstruction, parser/crypto or provider conformance proof',
 'Selected-origin refinement allows unrelated-origin stuttering; a native joint account/history product must be supplied',
 'Exposure never decreases; no cancellation/settlement/reclamation or transport-delivery transitions in this extension',
 'No exhaustive Quint state exploration, liveness, remote exactly-once or performance claim',
 'Org export succeeded; host lacks optional htmlize source-fontification support'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 27 routes; 24 Lean declarations; 40 Quint controls; ten independently observed counterexamples; 70 bounded samples; pins unchanged')
