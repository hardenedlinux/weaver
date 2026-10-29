from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-append-handoff'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==38 and all(c['exit']==0 for c in commands)
for c in commands:
 assert c['sourceSha256'],c['label']
 for p,digest in c['sourceSha256'].items():assert hashlib.sha256((root/p).read_bytes()).hexdigest()==digest,(c['label'],p)
log=(out/'LlmAppendHandoff.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmAppendHandoff\.",log,re.M))==13
assert '77 passing' in (out/'tests.log').read_text()
assert '8 passing' in (out/'counterexamples.log').read_text()
assert '72 passing' in (out/'manifest-regression.log').read_text()
for init in ['init','cutFirst','appended','pending','switched','lateCommitted','preCutPending','recovered','oldOwner']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 129 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==13
assert len(json.loads((out/'counterexample-observations.json').read_text()))==8
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==33
assert len(json.loads((out/'diagram-validation.json').read_text()))==56
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
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==25
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmAppendHandoff.lean','proofs/qunit/LlmAppendHandoff.qnt','proofs/check_llm_append_handoff.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=38,leanModules=25,printedDeclarations=13,
 quintControls=77,newControls=38,guardedNewControls=30,directlyImportedCheckpointControls=39,counterexamples=8,parentRegressionControls=72,
 boundedSamples=90,maxPostInitializerSteps=30,seed=251,fourArtifactRows=13,englishOrgDocuments=129,d2Pairs=56,historicalManifestsUnchanged=33,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,
 workingSourceDrift='P17: two control-plane import paths only; native target ABI not qualified',
 dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Concurrent actual WAL flush, durable cut/successor handoff, current live-tail preservation, protected reference-union GC and original account/source composition',
 limitations=['Native body/admission descriptor ordering, idempotent operation lookup, atomic seal/open and root/append descriptor publication remain IO premises',
 'Safe initial complete representation, immutable typed objects, durable root and exclusive Rust native handle ownership are required',
 'One unresolved cut and one uncommitted settlement frame per account lane; speculative multi-candidate before-images and arbitrary-account products are not proved',
 'Old pending owner continuation remains bound to earlier source/account reconciliation; bounded continuation liveness is not proved',
 'Independent financial/publication/source authorities and accepted-candidate archive remain retained; admission/cut minimum publication is a required native extension because unchanged financial/checkpoint anchors cannot detect rollback of pending admissions',
 'Unknown-source hold theorem requires inherited original-key binding for every commit path; finite pending fixture and actual hold are separately checked',
 'lastAuthorized and attempted are independent ghost mutation monitors, not production capabilities',
 'No native crash injection, codec/hash/ABI qualification, lease product, provider exactly-once, exhaustive exploration, recovery liveness or performance claim',
 'Optional htmlize fontification unavailable during successful Org export'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 38 routes; 13 Lean declarations; 38 new plus 39 imported controls; eight decoded violations; 90 samples; pins unchanged')
