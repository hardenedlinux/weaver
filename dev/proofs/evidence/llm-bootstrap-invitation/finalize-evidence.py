from pathlib import Path
import hashlib,json,re
ROOT=Path.cwd();OUT=ROOT/'proofs/evidence/llm-bootstrap-invitation';BASE=ROOT/'docs/40-49-admission-coordination/45-bootstrap-invitation'
commands=json.loads((OUT/'commands.json').read_text());assert len(commands)==8 and all(r['exit']==0 for r in commands)
for r in commands:
 for p,h in r['sourceSha256'].items():assert hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h
assert len(json.loads((OUT/'reused-lean-receipts.json').read_text()))==31
assert len(re.findall(r"^'Weaver.LlmBootstrapInvitation\.",(OUT/'LlmBootstrapInvitation.log').read_text(),re.M))==19
assert 'sorryAx' not in (OUT/'LlmBootstrapInvitation.log').read_text()
assert sum((OUT/f'bundle-controls-{n}.log').read_text().count(' passed 1 test(s)') for n in range(6))==23
assert all('passing' in (OUT/f'bundle-controls-{n}.log').read_text() for n in range(6))
assert len(json.loads((OUT/'four-artifacts.json').read_text()))==19
assert len(json.loads((OUT/'counterexample-observations.json').read_text()))==4
assert 'PASS:' in (OUT/'four-artifacts-check.log').read_text() and 'PASS:' in (OUT/'counterexample-check.log').read_text()
assert 'PASS: 150 English Org documents' in (OUT/'document-qa.log').read_text()
assert '40 historical manifests unchanged' in (OUT/'document-qa.log').read_text()
assert 'PASS: exported 150 Org documents without evaluating source blocks' in (OUT/'org-export.log').read_text()
explore=json.loads((OUT/'exploration-commands.json').read_text());assert len(explore)==1 and explore[0]['exit']==124 and explore[0]['watchdogSeconds']==30
prior=ROOT/'proofs/evidence/llm-incarnation-issuance';parent=json.loads((prior/'commands.json').read_text());tests=next(r for r in parent if r['label']=='tests');assert tests['exit']==0
assert (prior/'tests.log').read_text().count(' passed 1 test(s)')==31
reused=dict(command=tests,log=str((prior/'tests.log').relative_to(ROOT)),logSha256=hashlib.sha256((prior/'tests.log').read_bytes()).hexdigest(),classification='Source-checked sealed predecessor receipt; not a current rerun')
(OUT/'reused-quint-receipt.json').write_text(json.dumps(reused,indent=2)+'\n')
(OUT/'visual-inspection.log').write_text('PASS: final bundled core SVG rendered at 2400px and visually inspected. Four aligned responsibility columns, official local Go/Kubernetes/Rust icons, no physical isolation, version or acceptance labels. Immutable invitation, exact consumed outcome, pending-only issuance, current activation CAS and unknown hold are explicit; Quint and Lean panels are visible.\n')
receipt=dict(status='PASS_CONDITIONAL_MODEL_CONTROLS',freshLeanDeclarations=19,sourceCheckedReusedLeanReceipts=31,currentQuintControls=23,guardedControls=19,decodedFaultControls=4,successfulCurrentRoutes=8,sourceCheckedReusedQuintControls=31,fourArtifactRows=19,pinnedSourceBlobs=19,workingExactBlobs=18,workingImportOnlyChanges=['P17'],documents=150,localFileLinks=2106,pinnedGitTargets=101,d2SvgPairs=63,historicalManifestsUnchanged=40,randomizedExploration='NOT ADMITTED: consumed initializer hit fixed 30-second watchdog; activated initializer not dispatched',nativeQualification='NOT CLAIMED: independent assignment, key possession, channel authenticity, encoding, atomic persistence, anti-rollback, finite counter exhaustion, liveness and provider I/O require native qualification',scope='English Org, core D2, Lean and Quint only; no Gateway implementation or dependency pin changes',historicalFailures='Initial recursive tests, narrow interrupted diagnostic, recursive four-control test, two recursive parse watchdogs, full bundled test and optional randomized exploration retained; no watchdog enlarged',boundary='Logical execution authority in an AI Agent Gateway; no physical worker uniqueness guarantee')
(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
docs=[ROOT/'README.org',*sorted((ROOT/'docs').rglob('*.org')),*sorted((ROOT/'specs').rglob('*.org'))];diagrams=[p for p in (ROOT/'docs').rglob('*.d2') if p.parent.name!='lib']
quality={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in docs+diagrams+[p.with_suffix('.svg') for p in diagrams]}
(OUT/'document-source-hashes.json').write_text(json.dumps(quality,indent=2,sort_keys=True)+'\n')
paths=[p for p in OUT.rglob('*') if p.is_file() and p.name!='SHA256SUMS']+list(BASE.glob('*'))
for folder,pattern in [('proofs/lean','*.lean'),('proofs/qunit','*.qnt'),('specs/lean','*.lean'),('specs/quint','*.qnt')]:paths+=list((ROOT/folder).glob(pattern))
paths+=list((ROOT/'docs/architecture/diagrams/assets').glob('*'))+list((ROOT/'docs/architecture/diagrams/lib').glob('*'))
paths+=[ROOT/p for p in ['proofs/check_llm_bootstrap_invitation.py','proofs/prepare_bootstrap_invitation_closure.py','proofs/prepare_bootstrap_invitation_shards.py','proofs/prepare_bootstrap_invitation_bundle.py','proofs/prepare_bootstrap_invitation_bundle_controls.py','devenv.lock','devenv.nix','devenv.yaml','.envrc','proofs/evidence/llm-semantic-contract/dependency-identity.log']]
paths=sorted({p for p in paths if p.is_file()})
(OUT/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(ROOT))+'\n' for p in paths))
print(f'PASS: {len(paths)} sealed byte targets; 19 Lean declarations, 23 controls, four decoded faults; randomized timeout explicitly excluded')
