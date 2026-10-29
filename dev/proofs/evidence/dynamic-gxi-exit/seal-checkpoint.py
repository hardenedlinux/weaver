from pathlib import Path
import json,hashlib,subprocess
out=Path(__file__).parent;cwd=Path.cwd();cache={}
def sha(p):
 p=Path(p);st=p.stat();key=(st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns)
 if key not in cache:cache[key]=hashlib.sha256(p.read_bytes()).hexdigest()
 return cache[key]
result=json.loads((out/'checkpoint-check.json').read_text());receipt=dict(result,auditDate='2026-10-20',workspace=str(cwd),head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),repair='Narrow JSON/parser umbrella I/O imports; keep ordinary interpreted source; share admitted pure dynamic mappings while preserving 98 independent lazy linker entries and every successful module load reference',primaryCandidate='official-abi/',compilerCorrection='Initial ABI-definition-only image build remains exploratory. The final candidate extracts and applies complete configured FLAGS_OPT/FLAGS_OBJ/FLAGS_DYN/DEFS_DYN from installed gambuild-C, including fwrapv and no-strict-aliasing.',sourceBuildBoundary='38 Core/POO interfaces and 8 stdlib interfaces rebuilt from high-level Scheme sources. Bootstrap image code is rebuilt from the exact installed lowered Scheme, not claimed a full high-level Gerbil/Gambit rebuild.',installedRuntimeBoundary='Normal installed gxi executable unchanged; configured runtime roots reproduced for passive instrumentation; normal installed shell-launcher runs also qualified.',cleanupBoundary='Every tracked Scheme-image reference is closed; separate C canary destructor executes. Process-wide foreign/OS resources remain under unchanged runtime ownership, not an exhaustive OS leak proof.',nativeInputAssumption='Single trusted owner and no concurrent package/input mutation; before/after checks are not an OS immutability or transient tampering proof.',formalBoundary='Lean invariants and finite official Quint controls retain explicit compiler/interpreter/dyld and quiescence premises. They do not prove the C compiler or Darwin.',preservedFailures=['Historical 15-second dynamic failures','Repeated natural late exit 24.355 seconds','Source-only interface omission; ignored trailing eval options','Thin-loader native hypotheses and 19.954-second failed gate','Initial import narrowing with missing utility owner; corrected but late 20.379-second run','First same-object unbatched control exceeded 15 seconds; unreaped original exit remains unknown despite later balanced cleanup and absent PID','Auxiliary formal syntax/type/controller-count failures and 20-second research-leaf watchdog failure'],counterEvidence='Later original and unbatched controls also pass; initial alternating batch may overlap an overdue control. No universal causal latency elimination or general speedup ratio is asserted.',operationIdentityBoundary='New native execution profile cannot reuse old AOT/profile receipts; shared physical image is not module, claim, budget, history or authorization identity. Final wire and Cedar Policy guards remain independent.',remainingOpen=['General order-sensitive/foreign plugin regression and host-wide notification availability','Native YAML and full defaults/normalization/diagnostic parity','Actual Gateway transport/store fault qualification and end-to-end performance'])
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
files={p for p in out.rglob('*') if p.is_file() and p.name!='SHA256SUMS' and '__pycache__' not in p.parts}
files.update(p for p in Path('docs/50-59-research-program/54-dynamic-gxi-exit').glob('*') if p.is_file())
for name in ['NativeDynamicImportBoundary','DynamicImageCustody','DynamicLoaderPublication']:
 files.add(Path('proofs/lean')/(name+'.lean'));files.add(Path('proofs/qunit')/(name+'.qnt'))
for row in json.loads((out/'clean-proof-receipt.json').read_text())['modules']:files.add(Path(row['source']))
for label in ['inputs-after.json','official-abi/inputs-after.json']:
 data=json.loads((out/label).read_text());files.update(Path(name) for name in data.get('closedByteInputs',data.get('byteInputs',{})) if Path(name).resolve().is_relative_to(cwd))
# Preserve all isolated artifacts and exact audited scripts, including rejected
# generations and same-object controls. The original previous checkpoint is read-only.
files.update(p for p in Path('.data/dynamic-gxi-exit-20261020').rglob('*') if p.is_file() and '__pycache__' not in p.parts)
lines=[]
for p in sorted(files,key=str):
 name=str(p.resolve().relative_to(cwd));lines.append(sha(p)+'  '+name)
(out/'SHA256SUMS').write_text('\n'.join(lines)+'\n');print('SEALED',len(lines),'new artifact/source/receipt byte targets')
