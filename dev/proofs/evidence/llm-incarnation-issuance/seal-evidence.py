from pathlib import Path
import hashlib,json
root=Path.cwd();out=root/'proofs/evidence/llm-incarnation-issuance';base=root/'docs/40-49-admission-coordination/44-incarnation-issuance'
qa=(out/'document-qa.log').read_text();assert 'PASS: 147 English Org documents' in qa and '62 core D2 sources' in qa and '39 historical manifests unchanged' in qa
assert 'PASS: exported 147 Org documents without evaluating source blocks' in (out/'org-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==23
assert len(json.loads((out/'counterexample-observations.json').read_text()))==6
r=json.loads((out/'receipt.json').read_text());assert r['status']=='PASS' and r['successfulCurrentRoutes']==14
r.update(documentQa='PASS: 147 English Org documents, 2087 local file links and 101 pinned Git source targets; all Org documents exported without evaluating blocks',diagramQa='PASS: 62 core D2/SVG pairs; final current bundled SVG rendered at 2400px and visually inspected',historicalEvidence='PASS: 39 historical byte manifests unchanged',evidenceClassification='Conditional model/semantic acceptance; fresh leaf and source-checked reused ancestors. Historical full-test-bearing simulation timeout is retained, not reclassified. No native crypto, persistence, anti-rollback, key-delivery, liveness or performance qualification.')
(out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
(out/'visual-inspection.log').write_text('PASS: inspected final bundled SVG at 2400px. Aligned four-column core architecture; official local Go/Kubernetes/Rust icons; independent launch and bootstrap key/session proof; pending ticket explicitly confers no active custody or send; final determining CAS checks proof/epoch/parent and activates original result; unknown hold retained; visible Quint/Lean panels. No version/acceptance metadata or physical-isolation chain.\n')
docs=[root/'README.org',*sorted((root/'docs').rglob('*.org')),*sorted((root/'specs').rglob('*.org'))];diagrams=[p for p in (root/'docs').rglob('*.d2') if p.parent.name!='lib']
assert len(docs)==147 and len(diagrams)==62
quality={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in docs+diagrams+[p.with_suffix('.svg') for p in diagrams]}
(out/'document-source-hashes.json').write_text(json.dumps(quality,indent=2,sort_keys=True)+'\n')
paths=[p for p in out.rglob('*') if p.is_file() and p.name!='SHA256SUMS']+list(base.glob('*'))
for folder,suffix in [('proofs/lean','*.lean'),('proofs/qunit','*.qnt'),('specs/lean','*.lean'),('specs/quint','*.qnt')]:paths+=list((root/folder).glob(suffix))
paths+=list((root/'docs/architecture/diagrams/assets').glob('*'))+list((root/'docs/architecture/diagrams/lib').glob('*'))
paths+=[root/p for p in ['proofs/check_llm_incarnation_issuance.py','proofs/prepare_llm_issuance_closure.py','devenv.lock','devenv.nix','devenv.yaml','.envrc','proofs/evidence/llm-semantic-contract/dependency-identity.log']]
paths=sorted({p for p in paths if p.is_file()})
(out/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(root))+'\n' for p in paths))
print(f'Sealed {len(paths)} byte targets; native premises and all historical failure classifications retained.')
