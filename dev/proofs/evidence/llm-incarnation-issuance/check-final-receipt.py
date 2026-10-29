from pathlib import Path
import hashlib,json,re,subprocess
root=Path.cwd();out=root/'proofs/evidence/llm-incarnation-issuance';commands=json.loads((out/'commands.json').read_text());assert len(commands)==14,len(commands)
assert all(r['exit']==0 for r in commands)
for r in commands:
 for path,h in r['sourceSha256'].items():assert hashlib.sha256((root/path).read_bytes()).hexdigest()==h,(r['label'],path)
 assert r['seconds']<=r['watchdogSeconds']+1
prior=root/'proofs/evidence/llm-caller-custody';ancestors=json.loads((out/'reused-lean-receipts.json').read_text());assert len(ancestors)==30
for r in ancestors:
 for path,h in r['sourceSha256'].items():assert hashlib.sha256((root/path).read_bytes()).hexdigest()==h
 assert Path(r['args'][-2]).is_file() and r['exit']==0
lean=(out/'LlmIncarnationIssuance.log').read_text();assert 'sorryAx' not in lean and 'error:' not in lean
assert len(re.findall(r"^'Weaver.LlmIncarnationIssuance\.",lean,re.M))==23
assert '31 passing' in (out/'tests.log').read_text() and '6 passing' in (out/'counterexamples.log').read_text()
assert '27 passing' in (out/'caller-regression.log').read_text()
for name in ['boot','issued','proven','ready','activated','competing','moved','revoked']:assert '[ok] No violation found' in (out/(name+'.log')).read_text(),name
pipeline=json.loads((out/'quint-test-pipeline.json').read_text());assert hashlib.sha256(Path(pipeline['path']).read_bytes()).hexdigest()==pipeline['sha256']
assert Path(pipeline['path']).read_text().splitlines()[pipeline['line']-1]==pipeline['text']
for name in ['check-source-receipts.py','check-working-sources.py','check-closure-certificate.py','check-four-artifacts.py','check-counterexample-observations.py']:
 p=subprocess.run(['python3',str(out/name)],capture_output=True,text=True,timeout=20);(out/name.replace('.py','.log')).write_text(p.stdout+p.stderr);assert p.returncode==0,p.stdout+p.stderr
history=list((root/'specs/evidence').glob('*/SHA256SUMS'))+[p for p in (root/'proofs/evidence').glob('*/SHA256SUMS') if p.parent!=out]
assert len(history)==39,len(history)
for manifest in history:
 for line in manifest.read_text().splitlines():
  h,path=line.split('  ',1);assert hashlib.sha256((root/path).read_bytes()).hexdigest()==h,(manifest,path)
assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()=='4df1f0233f9a78e5a3ea8a1a0d8aaca983698b8d'
for name in ['proofs/lean/LlmIncarnationIssuance.lean','proofs/qunit/LlmIncarnationIssuance.qnt','proofs/check_llm_incarnation_issuance.py','proofs/prepare_llm_issuance_closure.py']:(out/Path(name).name).write_bytes((root/name).read_bytes())
pins={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in ['devenv.lock','devenv.nix','devenv.yaml','.envrc','proofs/evidence/llm-semantic-contract/dependency-identity.log']}
receipt=dict(status='PASS',scope='Conditional executable design proof; no Gateway implementation',successfulCurrentRoutes=14,freshLeanLeaves=1,reusedUnchangedLeanAncestors=30,printedNewDeclarations=23,currentQuintControls=31,predecessorCallerControls=27,exportedMutations=6,sampledInitializers=8,boundedSamples=80,maxPostInitializationSteps=30,seed=293,reviewedSourceFiles=19,exactWorkingMatches=18,unknownHold12=2,providerCallsInMutationTraces=0,fourArtifactRows=23,englishOrgDocuments=147,coreDiagramPairs=62,historicalManifests=39,dependencyIdentities=pins,historicalFailureBoundary='Prior category standalone-20s typecheck remains failed. Current full test-bearing boot-30s attempt is retained as timeout; only the IR-equivalent simulation closure passed sampling.',premises=['Independent authentic original-bound launch authorization and credential delivery','Exact key/session/audience/purpose transcript verification','One protected atomic full pre/post history for issue, proof and actual custody activation','Authentic current outer revision and inherited custody parent','Nondecreasing time and non-reused native counter/identity namespaces','Initialized actual custody/account prefixes; Safe handoff and original-source budget binding'],notProved=['Native crypto or key secrecy/process attestation','Kubernetes RBAC/bootstrap credential delivery','Native durability/anti-rollback and codec refinement','Same-incarnation rotation bootstrap or successor-launch liveness','Automatic Quint-to-Lean/native refinement','Provider IO exactly-once or performance'])
receipt['requestedCliSeed']=293
receipt['printedReproductionSeeds']={name:re.findall(r'Use --seed=(\S+)',(out/(name+'.log')).read_text()) for name in ['boot','issued','proven','ready','activated','competing','moved','revoked']}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: 14 current routes; fresh Lean leaf / 30 source-checked ancestors / 23 declarations; 31+27 controls / 6 decoded mutations / 80 bounded simulations; native premises and historical failures explicit')
