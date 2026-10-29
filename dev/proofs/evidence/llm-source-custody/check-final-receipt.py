from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-source-custody'
commands=json.loads((out/'commands.json').read_text())
assert len(commands)==41 and all(c['exit']==0 for c in commands)
for c in commands:
 assert c['sourceSha256'],c['label']
 for p,digest in c['sourceSha256'].items():assert hashlib.sha256((root/p).read_bytes()).hexdigest()==digest,(c['label'],p)
log=(out/'LlmSourceCustody.log').read_text()
assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmSourceCustody\.",log,re.M))==13
assert '23 passing' in (out/'tests.log').read_text()
assert '7 passing' in (out/'counterexamples.log').read_text()
assert '103 passing' in (out/'join-regression.log').read_text()
for init in ['init','armed','handed','recovered','committed','transferredCommit','resolvedCommit','restarted','closed']:
 assert 'No violation found' in (out/(init+'.log')).read_text()
assert 'exported 138 Org documents' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==13
assert len(json.loads((out/'counterexample-observations.json').read_text()))==7
assert len(json.loads((out/'source-receipt-check.json').read_text()))==19
assert len((out/'historical-manifests.log').read_text().splitlines())==36
assert len(json.loads((out/'diagram-validation.json').read_text()))==59
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
 if c['label'] not in ['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff','LlmAdmissionFloor','LlmSourceJoin','LlmSourceCustody']:continue
 p=root/c['args'][-1]
 graph.append(dict(module=c['label'],path=str(p.relative_to(root)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),imports=re.findall(r'^import (\w+)',p.read_text(),re.M)))
assert len(graph)==28
(out/'dependency-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for name in ['proofs/lean/LlmSourceCustody.lean','proofs/qunit/LlmSourceCustody.qnt','proofs/check_llm_source_custody.py']:
 p=root/name;(out/p.name).write_bytes(p.read_bytes())
(out/'versions.log').write_text(''.join(subprocess.check_output(args,text=True) for args in [['elan','run','leanprover/lean4:v4.34.1','lean','--version'],['quint','--version'],['d2','--version']]))
receipt=dict(status='pass',commandRoutes=41,leanModules=28,printedDeclarations=13,
 quintControls=23,newControls=23,guardedNewControls=16,parentJoinOwnControls=27,parentFloorOwnControls=33,parentAccountControls=43,
 counterexamples=7,parentRegressionControls=103,boundedSamples=90,maxPostInitializerSteps=30,seed=269,
 fourArtifactRows=13,englishOrgDocuments=138,d2Pairs=59,historicalManifestsUnchanged=36,
 freshlyVerifiedSourceBlobs=19,workingSourceFiles=19,workingSourceBaselineMatches=18,
 workingSourceDrift='P17: two control-plane import paths only; native ABI not qualified',
 dependencyPinsChanged=False,gatewayImplementationChanged=False,
 scope='Recoverable original source custody, current custody fencing at actual admission floor CAS, immutable original outcome and actual initialized source-join/account composition',
 limitations=['Durable arm, protected transfer fence, authentic same-authority resolution and exact semantic sameIntent are native owner contracts',
 'Abstract commit couples actual floor publication and durable original outcome; native transaction or authoritative log-derived outcome is required',
 'The model conservatively serializes source mutations while armed; no cross-store atomicity implementation is proved',
 'Custody fence and Gateway execution-owner generation are distinct; transfer grants no new execution owner',
 'One original custody lifetime; no eventual recovery or fairness theorem; original pending constraints and replay pins are retained',
 'The old-permit mutation invokes an actual inherited append; other mutations demonstrate descriptor/control violations without claiming provider sends or financial duplicates',
 'The rollback mutation uses a ghost observation, not a co-rollback detector or proof of independent authority durability',
 'Unknown-source hold composition requires the inherited original-key/source binding and initialized safe account prefix',
 'Bounded sampling is not exhaustive model checking; no native IO/ABI/codec, provider exactly-once or performance qualification',
 'Optional htmlize fontification unavailable during successful Org export'],
 leanEvidenceResumedAfterInputHashVerification=True,
 preliminaryDiagnostics=sorted(p.name for p in out.glob('preliminary-*')))
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 41 routes; 13 Lean declarations; 23 new controls and 103 parent regression controls; seven decoded violations; 90 samples; pins unchanged')
