from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-source-join'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==40 and all(c['exit']==0 for c in commands)
for c in commands:
 assert c['sourceSha256'],c['label']
 for p,digest in c['sourceSha256'].items():assert hashlib.sha256((root/p).read_bytes()).hexdigest()==digest,(c['label'],p)
log=(out/'LlmSourceJoin.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmSourceJoin\.",log,re.M))==14
assert '103 passing' in (out/'tests.log').read_text()
assert '7 passing' in (out/'counterexamples.log').read_text()
assert '71 passing' in (out/'floor-regression.log').read_text()
for init in ['init','staged','accountChanged','sourceChanged','sourceReallowed','fenced','appendInit','appendStaged','appendPublished']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 135 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==14
assert len(json.loads((out/'counterexample-observations.json').read_text()))==7
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==35
assert len(json.loads((out/'diagram-validation.json').read_text()))==58
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
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff','LlmAdmissionFloor','LlmSourceJoin']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==27
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmSourceJoin.lean','proofs/qunit/LlmSourceJoin.qnt','proofs/check_llm_source_join.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=40,leanModules=27,printedDeclarations=14,
 quintControls=103,newControls=27,guardedNewControls=20,directlyImportedFloorControls=33,directlyImportedAccountControls=43,
 counterexamples=7,parentRegressionControls=71,boundedSamples=90,maxPostInitializerSteps=30,seed=263,
 fourArtifactRows=14,englishOrgDocuments=135,d2Pairs=58,historicalManifestsUnchanged=35,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,
 workingSourceDrift='P17: two control-plane import paths only; new import targets native ABI not qualified',
 dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Exact original proposal/account/source/floor join, current source allowance at final determining CAS and actual initialized floor/account/source composition',
 limitations=['Recoverable native source-owner custody and actual cross-store mutation/CAS serialization are premises; no distributed transaction or quorum implementation is proved',
 'Aggregate source revision must cover every relevant external source/Policy/history mutation within the same qualified namespace; independent recovery/invalidation coverage is native qualification',
 'Lean binds actual source qualification/generation; Quint varies external aggregate source revision while inherited source generation is fixed',
 'Full typed account and proposal identity may use native authenticated immutable commitments only under qualified codec/collision/current-read assumptions',
 'Same-floor account mutation trace legitimately commits original known usage; other traces retain the pending original hold; provider execution is independently checked unchanged',
 'Unknown-source hold theorem requires inherited original-key binding for every account path; original result and reservation uniqueness are separately composed',
 'Protected floor/body/archive and pending intent histories remain retained; inherited one unresolved cut and one uncommitted settlement frame per account lane remain',
 'lastChecked and attempted are negative-test observations, not native execution permits',
 'No native IO/ABI/codec qualification, general external dependency proof, arbitrary-account product, provider exactly-once, exhaustive exploration, recovery liveness or performance claim',
 'Optional htmlize fontification unavailable during successful Org export'],
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 40 routes; 14 Lean declarations; 27 new plus 76 imported controls; seven decoded violations; 90 samples; pins unchanged')
