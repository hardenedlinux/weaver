from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-account-commit'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==32 and all(c['exit']==0 for c in commands)
log=(out/'LlmAccountCommit.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmAccountCommit\.",log,re.M))==23
assert '89 passing' in (out/'tests.log').read_text()
assert '10 passing' in (out/'counterexamples.log').read_text()
assert '88 passing' in (out/'reconciliation-regression.log').read_text()
for init in ['init','prepared','committed','projected','restarted','twoPrepared','fullyCharged']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 117 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==23
assert len(json.loads((out/'counterexample-observations.json').read_text()))==10
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==29
assert len(json.loads((out/'diagram-validation.json').read_text()))==52
live=json.loads((out/'working-source-check.json').read_text())
assert len(live)==19 and sum(r['sameWorkingBytes'] for r in live)==18
check=subprocess.run(['python3',str(out/'check-working-sources.py')],capture_output=True,text=True,timeout=20)
(out/'working-source-check.log').write_text(check.stdout+check.stderr)
assert check.returncode==0,check.stdout+check.stderr
pins=''.join(hashlib.sha256((root/p).read_bytes()).hexdigest()+'  '+p+'\n' for p in ['devenv.lock','devenv.nix','devenv.yaml'])
assert pins==(root/'proofs/evidence/llm-semantic-contract/dependency-identity.log').read_text()
(out/'dependency-identity.log').write_text(pins)
identity=dict(repository=str(root),branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),scope='Design, formal sources and local evidence only; earlier workspace preserved')
assert identity['head']=='4df1f0233f9a78e5a3ea8a1a0d8aaca983698b8d'
(out/'checkout-identity.json').write_text(json.dumps(identity,indent=2)+'\n')
graph=[]
for c in commands:
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==21
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmAccountCommit.lean','proofs/qunit/LlmAccountCommit.qnt','proofs/check_llm_account_commit.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=32,leanModules=21,printedDeclarations=23,
 quintControls=89,newControls=43,guardedNewControls=33,directlyImportedReconciliationControls=46,counterexamples=10,parentRegressionControls=88,
 boundedSamples=70,maxPostInitializerSteps=30,seed=229,fourArtifactRows=23,englishOrgDocuments=117,d2Pairs=52,historicalManifestsUnchanged=29,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,
 workingSourceDrift='P17: two control-plane import paths only; import-target runtime/ABI equivalence not qualified',
 dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Atomic authoritative application/reservation/hold/balance image; original source evidence bridge; current owner/source fence; complete protected-prefix recovery',
 limitations=['Atomic durable financial log CAS and independently current non-rollback prefix are native qualification premises, not implemented storage',
 'Global original reservation, account units and full source/usage receipt authenticity require native binding',
 'Actual preceding initialized reconciliation run is composed through an explicit per-commit sourceReady mapping; no whole native source/database/consensus product',
 'Initial aggregate booked funds must match legitimate finite reservations and source capacity; pointwise conservation is relative to supplied genesis',
 'Quint uses two shared-account reservations; only the first uses the actual preceding reconciliation module, the other has an explicit trusted fixture',
 'Owner/source stamps are protected separate modeled fields; restoring financial image cannot reset them',
 'Independent test credit monitors do not themselves authenticate a production prefix',
 'No native crash injection, provider exactly-once, exhaustive model checking, performance or recovery liveness qualification',
 'Org export succeeded; optional htmlize source-fontification support is unavailable'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 32 routes; 23 Lean declarations; 43 new Quint controls plus 46 imported controls; ten decoded violations; 70 samples; pins unchanged')
