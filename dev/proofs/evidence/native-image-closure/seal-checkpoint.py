from pathlib import Path
import hashlib,json,subprocess
p=Path(__file__).parent;root=Path('.data/native-image-closure-20261020');cwd=Path.cwd();cache={}
assert (p/'SHA256SUMS').stat().st_size==0,'Sealed generation is immutable'
def sha(path):
 st=path.stat();key=(st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns)
 if key not in cache:cache[key]=hashlib.sha256(path.read_bytes()).hexdigest()
 return cache[key]
result=json.loads((p/'checkpoint-check.json').read_text())
receipt=dict(result,auditDate='2026-10-20',workspace=str(cwd),head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 rootCause='First-use F_CHECK_LV library validation plus synchronous dyld image notification waits; the kernel/service endpoint remains unidentified. Actual checks and cleanup remain enabled.',
 repair='Preserve 238 original source-bound lazy entries in four exported-symbol-conflict-free images, compared against the same 238 objects in 147 images. Preserve 22 excluded native bodies and every one of 260 logical acquisitions/closes.',
 compilerBoundary='98 prior full-profile objects verified and reused; 140 additional lowered Scheme units compiled with the complete installed configured flags. Original interpreted fixture unchanged. No fixture AOT or general high-level Gerbil compiler repair claimed.',
 linkCorrection='Recorded installed SDK stubs used for both cells after SDK26 rejected legacy pow import; same C objects and full compiler semantics, inherited deployment target, real libSystem import. Original failed link evidence retained. No dependency pin or global SDK change.',
 attributionLimit='Deterministic mapping reduction and same-object reversed-order paired controls support the packaging mechanism. Shared OS/runtime caches, service queueing and scheduling remain uncontrolled; no universal latency or exact source-only speedup ratio.',
 coldDefinition='Fresh interpreter process and selected-image paths/inodes/UUIDs. Four ordinary protected-shell cold-launcher generations use disjoint UUIDs and no observer/epilogue; common installed runtime and host caches shared.',
 inputBoundary='Complete actual Scheme body/interface closure, selected generated C/objects/images, source manifests and recorded tool ABI checked. OS and foreign system libraries remain trusted; token filter is a trusted-source heuristic, not an untrusted Scheme sandbox.',
 formalBoundary='18 freshly checked Lean modules, 13 new declarations and 15 official finite Quint controls including four unsafe counterexamples. External source commitment and actual effect guard compose; compiler correctness, truthful observations, quiescence and native latency remain premises or measured evidence.',
 retainedFailures='Four primary control first-use deadline failures; expanded SDK link rejection, duplicate-symbol rejection, wrong-alias native exit70 and initial Lean syntax rejection. All 51 historical manifests unchanged, including previous failed candidate starts.',
 publicationBoundary='Object/image completion records qualify local single-writer publication; no distributed atomicity or anti-rollback protocol implementation claimed. Physical image identity never mints dispatch authority or resets claim, budget or history.',
 cleanupBoundary='All primary matrix references closed with no error/outstanding reference; independent native destructor probe completes LU. Ordinary shell samples have no per-handle observer, so complementary evidence is reported separately.',
 nextBoundary='Deploying the profile into any other runtime or workload requires separate source-bound qualification. Actual Gateway control/transport/store code remains design-only.',
 gatewayImplementation=False)
(p/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
files={x for x in p.rglob('*') if x.is_file() and x.name!='SHA256SUMS' and '__pycache__' not in x.parts};files.update(x for x in root.rglob('*') if x.is_file() and '__pycache__' not in x.parts);files.update(x for x in Path('docs/50-59-research-program/56-native-image-closure').glob('*') if x.is_file());files.add(Path('proofs/qunit/NativeLocatorClosure.qnt'))
for r in json.loads((p/'clean-proof-receipt.json').read_text())['modules']:files.add(Path(r['source']))
for name in ['docs/architecture/diagrams/lib/theme.d2','docs/architecture/diagrams/assets/go.svg','docs/architecture/diagrams/assets/rust.svg']:files.add(Path(name))
(p/'SHA256SUMS').write_text('\n'.join(sha(x)+'  '+str(x.resolve().relative_to(cwd)) for x in sorted(files,key=str))+'\n');print('SEALED',len(files),'targets')
