from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-execution-reconciliation'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==31 and all(c['exit']==0 for c in commands)
log=(out/'LlmExecutionReconciliation.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmExecutionReconciliation\.",log,re.M))==17
assert '88 passing' in (out/'tests.log').read_text()
assert '10 passing' in (out/'counterexamples.log').read_text()
assert '42 passing' in (out/'executor-regression.log').read_text()
for init in ['init','burned','offered','negativeDecision','terminalDecision','sourceApplied','usageApplied']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 114 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==17
assert len(json.loads((out/'counterexample-observations.json').read_text()))==10
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==28
assert len(json.loads((out/'diagram-validation.json').read_text()))==51
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
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==20
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmExecutionReconciliation.lean','proofs/qunit/LlmExecutionReconciliation.qnt','proofs/check_llm_execution_reconciliation.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=31,leanModules=20,printedDeclarations=17,
 quintControls=88,newControls=46,guardedNewControls=36,importedExecutorControls=42,counterexamples=10,parentRegressionControls=42,
 boundedSamples=70,maxPostInitializerSteps=30,seed=227,fourArtifactRows=17,englishOrgDocuments=114,d2Pairs=51,historicalManifestsUnchanged=28,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,
 workingSourceDrift='P17: two control-plane import paths only; import-target runtime/ABI equivalence not qualified',
 dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Dispatch closure and immutable resolution; actual executor/source composition; linked terminal, usage and original account application',
 limitations=['Native complete non-rollback closed prefix and exhaustive logical final-offer mediation remain premises',
 'Actual executor step mapping and initialized executor/source prefixes plus exact original identity binding must be supplied',
 'Source ledger and admission source image remain separate typed projections; native authoritative publication adapter is not implemented',
 'Account is a selected-reservation logical CAS; atomic application-ID/delta persistence and anti-rollback storage recovery remain native gates',
 'Quint imports executor and abstracts source applications; Lean uses actual source transitions and a full-state recovery predicate',
 'Whole-call terminal and final usage truth, original attribution and contradictory evidence quarantine require qualified native inputs',
 'Unknown work stays held; no automatic uncertain-burn reclamation, provider exactly-once delivery or recovery liveness claim',
 'No native transport/storage, exhaustive model checking or performance qualification',
 'Org export succeeded; optional htmlize source-fontification support is unavailable'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 31 routes; 17 Lean declarations; 46 new Quint controls plus 42 imported controls; ten decoded violations; 70 samples; pins unchanged')
