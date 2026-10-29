from pathlib import Path
import hashlib,json
root=Path.cwd();out=root/'proofs/evidence/llm-caller-custody';base=root/'docs/40-49-admission-coordination/43-caller-custody'
assert 'PASS: 144 English Org documents' in (out/'document-qa.log').read_text()
assert '61 core D2 sources' in (out/'document-qa.log').read_text()
assert '38 historical manifests unchanged' in (out/'document-qa.log').read_text()
assert 'PASS: exported 144 Org documents' in (out/'org-export.log').read_text()
assert 'PASS: re-exported 3 current Org documents' in (out/'org-current-export.log').read_text()
assert len(json.loads((out/'four-artifacts.json').read_text()))==22
assert len(json.loads((out/'counterexample-observations.json').read_text()))==7
receipt=json.loads((out/'receipt.json').read_text());assert receipt['status']=='SEMANTIC_CHECKS_PASS_RESOURCE_GATE_FAILED'
assert receipt['successfulRoutes']==42 and receipt['timeoutRoutes']==1
receipt.update(documentQa='PASS: 144 English Org documents and 2069 local links; current three documents re-exported',diagramQa='PASS: 61 D2/SVG pairs; final current SVG inspected at 2400px; staging is explicitly inert and final CAS appends the joint event',historicalEvidence='PASS: 38 historical manifests unchanged',standaloneGateUnresolved='Fixed 20-second standalone typecheck timed out; not reported green. Official test pipeline completed typechecking before passing controls.')
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
(out/'visual-inspection.log').write_text('PASS: final SVG rendered at 2400px and visually inspected. Four aligned columns, readable core cards, official bundled Go/Kubernetes/Rust icons and Quint/Lean panels. Staging explicitly changes no authority or external send; only the final atomic permit/parent/source join appends the grant/outcome event. No versions, acceptance counts, hardware or physical-isolation chain.\n')
documents=[root/'README.org',*sorted((root/'docs').rglob('*.org')),*sorted((root/'specs').rglob('*.org'))]
diagrams=[p for p in (root/'docs').rglob('*.d2') if p.parent.name!='lib']
assert len(documents)==144 and len(diagrams)==61
quality={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in documents+diagrams+[p.with_suffix('.svg') for p in diagrams]}
(out/'document-source-hashes.json').write_text(json.dumps(quality,indent=2,sort_keys=True)+'\n')
paths=[p for p in out.rglob('*') if p.is_file() and p.name!='SHA256SUMS']
paths+=list(base.glob('*'))
for folder,suffix in [('proofs/lean','*.lean'),('proofs/qunit','*.qnt'),('specs/lean','*.lean'),('specs/quint','*.qnt')]:paths+=list((root/folder).glob(suffix))
paths+=list((root/'docs/architecture/diagrams/assets').glob('*'))+list((root/'docs/architecture/diagrams/lib').glob('*'))
paths+=[root/p for p in ['proofs/check_llm_caller_custody.py','proofs/prepare_llm_caller_closure.py','devenv.lock','devenv.nix','devenv.yaml','.envrc','proofs/evidence/llm-semantic-contract/dependency-identity.log']]
paths=sorted({p for p in paths if p.is_file()})
(out/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(root))+'\n' for p in paths))
print(f'Sealed {len(paths)} byte targets. Resource-gate failure remains explicit in the final receipt.')
