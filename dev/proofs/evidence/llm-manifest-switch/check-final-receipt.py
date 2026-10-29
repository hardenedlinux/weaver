from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-manifest-switch'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==35 and all(c['exit']==0 for c in commands)
log=(out/'LlmManifestSwitch.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmManifestSwitch\.",log,re.M))==12
assert '72 passing' in (out/'tests.log').read_text()
assert '8 passing' in (out/'counterexamples.log').read_text()
assert '79 passing' in (out/'checkpoint-regression.log').read_text()
for init in ['init','staged','switched','acknowledged','deleted','restarted','twoRecords']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 126 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==12
assert len(json.loads((out/'counterexample-observations.json').read_text()))==8
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==32
assert len(json.loads((out/'diagram-validation.json').read_text()))==55
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
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==24
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmManifestSwitch.lean','proofs/qunit/LlmManifestSwitch.qnt','proofs/check_llm_manifest_switch.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=35,leanModules=24,printedDeclarations=12,
 quintControls=72,newControls=33,guardedNewControls=25,directlyImportedCheckpointControls=39,counterexamples=8,parentRegressionControls=79,
 boundedSamples=70,maxPostInitializerSteps=30,seed=241,fourArtifactRows=12,englishOrgDocuments=126,d2Pairs=55,historicalManifestsUnchanged=32,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,
 workingSourceDrift='P17: two control-plane import paths only; runtime/ABI equivalence not qualified',
 dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Durable current-manifest switch, result readback, immutable exact-object deletion, complete-path preservation and actual checkpoint/WAL/account/source composition',
 limitations=['Native object/root persistence, atomic root CAS and actual-unlink fencing remain qualification premises',
 'Complete initial representation, immutable typed records, exclusive storage owner and authenticated source/Policy facts are required',
 'Root crash durability does not replace independent non-rollback publication and financial anchors',
 'Represented WAL sequence is fixed during the cut; concurrent append-generation rollover and independent reader lease recovery are not proved',
 'Protected financial journal, outcome archive and canonical registry remain retained',
 'Unknown-source hold theorem requires inherited original-key binding for every relevant commit path; finite hold fixture is unconsumed',
 'lastDeleteAuthorized is a ghost mutation-test monitor, not a native authority',
 'No native crash injection, codec/hash/ABI qualification, provider exactly-once delivery, exhaustive exploration, liveness or performance claim',
 'Optional htmlize fontification is unavailable during successful Org export'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 35 routes; 12 Lean declarations; 33 new plus 39 imported controls; eight decoded violations; 70 samples; pins unchanged')
