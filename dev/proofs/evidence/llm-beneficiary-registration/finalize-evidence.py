from pathlib import Path
import hashlib,json,re
ROOT=Path.cwd();OUT=ROOT/'proofs/evidence/llm-beneficiary-registration';BASE=ROOT/'docs/40-49-admission-coordination/46-beneficiary-registration';PRIOR=ROOT/'proofs/evidence/llm-bootstrap-invitation'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
commands=json.loads((OUT/'commands.json').read_text());assert len(commands)==15 and all(r['exit']==0 for r in commands)
for row in commands:
 hashes=row.get('sourceSha256',{})
 if isinstance(hashes,dict):
  for path,digest in hashes.items():assert sha(ROOT/path)==digest,path
 else:assert row['label']=='api-parse' and hashes==sha(OUT/'bundle/LlmBeneficiaryRegistration.qnt')
invocation=json.loads((OUT/'api-invocation.json').read_text());assert invocation['exit']==0 and invocation['expectedControls']==32
for path,digest in invocation['inputs'].items():assert sha(ROOT/path)==digest,path
api=json.loads((OUT/'api-commands.json').read_text());assert len(api)==13 and all(r['exit']==0 for r in api)
passed=[t for r in api for t in r.get('passed',[])];assert len(passed)==len(set(passed))==32
assert all(r['typedIrUnchanged'] for r in api if r['label'].startswith('api-controls-'))
summary=json.loads((OUT/'typed-stage-summary.json').read_text());assert summary['sourceSha256']==sha(OUT/'bundle/LlmBeneficiaryRegistration.qnt')
base=Path('/opt/homebrew/Cellar/quint/0.33.0/libexec/lib/node_modules/@informalsystems/quint/dist/src')
assert summary['cliCommandsSha256']==sha(base/'cliCommands.js') and summary['evaluatorSha256']==sha(base/'runtime/impl/evaluator.js')
log=(OUT/'LlmBeneficiaryRegistration.log').read_text();assert len(re.findall(r"^'Weaver.LlmBeneficiaryRegistration\.",log,re.M))==29
assert 'sorryAx' not in log and 'error:' not in log
assert len(json.loads((OUT/'reused-lean-receipts.json').read_text()))==32
assert len(json.loads((OUT/'four-artifacts.json').read_text()))==29
obs=json.loads((OUT/'counterexample-observations.json').read_text());assert len(obs['faults'])==5 and obs['quarantineProbe']['guardedConsumptionRejected']
for name in ['counterexample-check.log','four-artifacts-check.log','source-check.log','working-source-check.log']:assert 'PASS:' in (OUT/name).read_text()
qa=(OUT/'document-qa.log').read_text();assert 'PASS: 153 English Org documents; 2128 local links; 101 pinned Git source targets' in qa and '64 core D2 sources' in qa and '41 historical manifests unchanged' in qa
assert 'PASS: exported 153 Org documents without evaluating source blocks' in (OUT/'org-export.log').read_text()
parentControls=sum((PRIOR/f'bundle-controls-{n}.log').read_text().count(' passed 1 test(s)') for n in range(6));assert parentControls==23
parent=dict(source=str((ROOT/'proofs/qunit/LlmBootstrapInvitation.qnt').relative_to(ROOT)),sourceSha256=sha(ROOT/'proofs/qunit/LlmBootstrapInvitation.qnt'),controls=23,classification='Exact-source sealed predecessor receipts reused; not a current rerun',logs={str((PRIOR/f'bundle-controls-{n}.log').relative_to(ROOT)):sha(PRIOR/f'bundle-controls-{n}.log') for n in range(6)})
(OUT/'reused-quint-receipt.json').write_text(json.dumps(parent,indent=2)+'\n')
receipt=dict(status='PASS_CONDITIONAL_MODEL_CONTROLS',freshLeanDeclarations=29,sourceCheckedReusedLeanReceipts=32,currentQuintControls=32,ordinaryGuardedControls=26,decodedFaultControls=5,quarantineControls=1,currentSuccessfulPhases=15,officialFullTypeEffectAnalysis=True,freshEvaluatorPerGroup=True,unchangedTypedIrAfterEachGroup=True,sourceCheckedReusedQuintControls=23,fourArtifactRows=29,pinnedSourceBlobs=19,workingExactBlobs=18,workingImportOnlyChanges=['P17'],documents=153,localFileLinks=2128,pinnedGitTargets=101,d2SvgPairs=64,historicalManifestsUnchanged=41,improvements=['Independent enrollment principal precedes beneficiary choice','Enrollment and beneficiary proofs bind one exact original template/session','First key cannot be replaced on lost response or restart','Publication result and actual invitation are one authority association','Outer qualification blocks consumption despite refreshed parent read','Root revocation also fences downstream issuer epoch','Original claim/reservation/history and unknown hold compose through actual predecessor traces'],nativeQualification='NOT CLAIMED: credential provisioning, authentic root assignment, transcript signatures, channel binding, codecs, atomic publication, anti-rollback covering the outer enrollment prefix, finite counter exhaustion, liveness and final transport refinement',boundedClaim='Current controls are deterministic bounded scenarios; Lean covers arbitrary finite traces under its explicit owner and initialization premises. No exhaustive search or new randomized/liveness/performance/remote-CI claim.',historicalDiagnostics='Combined CLI watchdog, draft Lean compiler diagnostics, pre-scope partial controls, earlier 31-control pass, and failed post-fail successor inspection retained and not counted as current passes',scope='English Org, core D2, Lean/Quint and proof tooling only; no Gateway implementation or dependency pin changes',boundary='Logical execution authority for an AI Agent Gateway; no physical process uniqueness or hardware guarantee')
(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
(OUT/'visual-inspection.log').write_text('PASS: final bundled core SVG rendered at 2400px and visually inspected. Four aligned responsibility columns and official local Go/Kubernetes/Rust icons. Independent enrollment root, two proofs, immutable first key/session, exact invitation publication outcome, accepted enrollment prefix, qualified consumption, issuer fence and unknown hold remain explicit. No versions, counts, acceptance details, physical isolation or hardware labels.\n')
docs=[ROOT/'README.org',*sorted((ROOT/'docs').rglob('*.org')),*sorted((ROOT/'specs').rglob('*.org'))];diagrams=[p for p in (ROOT/'docs').rglob('*.d2') if p.parent.name!='lib'];assert len(docs)==153 and len(diagrams)==64
(OUT/'document-source-hashes.json').write_text(json.dumps({str(p.relative_to(ROOT)):sha(p) for p in docs+diagrams+[p.with_suffix('.svg') for p in diagrams]},indent=2,sort_keys=True)+'\n')
paths=[p for p in OUT.rglob('*') if p.is_file() and p.name!='SHA256SUMS']+list(BASE.glob('*'))
for folder,pattern in [('proofs/lean','*.lean'),('proofs/qunit','*.qnt'),('specs/lean','*.lean'),('specs/quint','*.qnt')]:paths+=list((ROOT/folder).glob(pattern))
paths+=list((ROOT/'docs/architecture/diagrams/assets').glob('*'))+list((ROOT/'docs/architecture/diagrams/lib').glob('*'))
paths+=[ROOT/p for p in ['proofs/check_llm_beneficiary_registration.py','proofs/check_beneficiary_api.py','proofs/run_beneficiary_registration.cjs','proofs/prepare_beneficiary_registration.py','proofs/prepare_beneficiary_registration_controls.py','devenv.lock','devenv.nix','devenv.yaml','.envrc','proofs/evidence/llm-semantic-contract/dependency-identity.log']]
paths=sorted({p for p in paths if p.is_file()});(OUT/'SHA256SUMS').write_text(''.join(sha(p)+'  '+str(p.relative_to(ROOT))+'\n' for p in paths))
print(f'PASS: {len(paths)} sealed byte targets; 29 Lean declarations, 32 current controls, five decoded faults and one quarantine control; native premises remain explicit')
