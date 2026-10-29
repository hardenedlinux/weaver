from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-checkpoint-truncation'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==36 and all(c['exit']==0 for c in commands)
log=(out/'LlmCheckpointTruncation.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmCheckpointTruncation\.",log,re.M))==16
assert '79 passing' in (out/'tests.log').read_text()
assert '10 passing' in (out/'counterexamples.log').read_text()
assert '83 passing' in (out/'wal-regression.log').read_text()
for init in ['init','built','published','confirmed','truncated','recovered','rolledBack','twoRecords','secondPublished']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 123 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==16
assert len(json.loads((out/'counterexample-observations.json').read_text()))==10
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==31
assert len(json.loads((out/'diagram-validation.json').read_text()))==54
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
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==23
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmCheckpointTruncation.lean','proofs/qunit/LlmCheckpointTruncation.qnt','proofs/check_llm_checkpoint_truncation.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=36,leanModules=23,printedDeclarations=16,
 quintControls=79,newControls=39,guardedNewControls=29,directlyImportedWalControls=40,counterexamples=10,parentRegressionControls=83,
 boundedSamples=90,maxPostInitializerSteps=30,seed=239,fourArtifactRows=16,englishOrgDocuments=123,d2Pairs=54,historicalManifestsUnchanged=31,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,
 workingSourceDrift='P17: two control-plane import paths only; import-target runtime/ABI equivalence not qualified',
 dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Complete checkpoint image and prefix witness; durable body and publication parent CAS; monotonic floor; physical local prefix deletion with actual WAL/account/source refinement',
 limitations=['Native checkpoint framing/serialization, object durability/availability and protected publication/fence persistence remain qualification premises',
 'Covered record lists are ghost/reference witnesses; physical prefix deletion is certified through complete image equivalence, not invented native log bytes',
 'Protected financial journal, original outcome archive and canonical source registry are retained; pruning those authorities or dedup facts is outside this result',
 'Initial funded balances, native finite-map/default completeness, original source and usage binding remain inherited premises',
 'Quint hold counterexample tests an unconsumed fixture hold; actual unknown-source consequence is conditional on the inherited binding for every account path',
 'Checkpoint and financial confirmation gates are separate; final native consumption cannot trust a remote cached active bit',
 'floorSeen is an independent test monitor, not production anti-rollback authority',
 'No Gateway code, native torn-byte/rename/fsync crash injection, arbitrary-many-provider product, exhaustive exploration, performance or bounded recovery liveness qualification',
 'Org export succeeded; optional htmlize source-fontification support is unavailable'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 36 routes; 16 Lean declarations; 39 new Quint controls plus 40 imported controls; ten decoded violations; 90 samples; pins unchanged')
