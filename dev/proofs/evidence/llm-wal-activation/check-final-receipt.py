from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-wal-activation'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==33 and all(c['exit']==0 for c in commands)
log=(out/'LlmWalActivation.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmWalActivation\.",log,re.M))==17
assert '83 passing' in (out/'tests.log').read_text()
assert '10 passing' in (out/'counterexamples.log').read_text()
assert '89 passing' in (out/'account-regression.log').read_text()
for init in ['init','flushed','submitted','anchored','replayed','activated','truncated']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 120 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==17
assert len(json.loads((out/'counterexample-observations.json').read_text()))==10
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==30
assert len(json.loads((out/'diagram-validation.json').read_text()))==53
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
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==22
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmWalActivation.lean','proofs/qunit/LlmWalActivation.qnt','proofs/check_llm_wal_activation.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=33,leanModules=22,printedDeclarations=17,
 quintControls=83,newControls=40,guardedNewControls=30,directlyImportedAccountControls=43,counterexamples=10,parentRegressionControls=89,
 boundedSamples=70,maxPostInitializerSteps=30,seed=233,fourArtifactRows=17,englishOrgDocuments=120,d2Pairs=53,historicalManifestsUnchanged=30,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,
 workingSourceDrift='P17: two control-plane import paths only; import-target runtime/ABI equivalence not qualified',
 dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Actual account projection; complete local WAL and retained candidate; protected commit/current confirmation; replay and final balance activation',
 limitations=['Native atomic record framing/durable flush, independently retained complete candidate and atomic protected financial commit remain qualification premises',
 'Prefix authenticity includes current complete non-forking history and protected owner/source stamps; old snapshots cannot define authority',
 'Activation is authority-serialized state; final native financial CAS must prevent stale remote active flags or delayed invalidations from granting money',
 'Original source/receipt binding and finite funded genesis remain inherited native premises',
 'Quint uses typed full records, not byte-level WAL parsing or power-loss recovery; native torn-byte validation is not established',
 'The inherited second shared-account reservation uses a trusted fixture; no arbitrary-many-provider runtime product',
 'Candidates remain retained in the reference; checkpoint pruning and candidate garbage collection require separate equivalence and outcome-retention proofs',
 'No Gateway code, native storage/crash injection, quorum implementation, exhaustive model checking, performance or recovery liveness qualification',
 'Org export succeeded; optional htmlize source-fontification support is unavailable'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 33 routes; 17 Lean declarations; 40 new Quint controls plus 43 imported controls; ten decoded violations; 70 samples; pins unchanged')
