from pathlib import Path
import json,hashlib
out=Path(__file__).parent
if any(q.is_file() and q.stat().st_size for q in [out/"SHA256SUMS",out.parent/"SHA256SUMS"]):
 raise SystemExit("Sealed generation; reproduce in fresh directories.")
root=Path('.data/dynamic-gxi-exit-20261020').resolve();parent=out.parent;cache={}
def sha(p):
 st=p.stat();key=(st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns)
 if key not in cache:cache[key]=hashlib.sha256(p.read_bytes()).hexdigest()
 return cache[key]
files=dict(json.loads((parent/'closed-inputs-before.json').read_text())['byteInputs'])
for folder in ['dynamic-images-official','canary-official']:
 for p in (root/folder).rglob('*'):
  if p.is_file():files[str(p)]=sha(p)
for p in [parent/'official-compiler-options.json',parent/'official-dynamic-images.json']:files[str(p.resolve())]=sha(p)
for name,h in files.items():assert sha(Path(name))==h,name
(out/'inputs-before.json').write_text(json.dumps(dict(byteInputs=files,scope='Complete prior native/source closure plus official-option images, canary and compiler-owner options; old experimental images remain immutable but are not selected by this run'),indent=2)+'\n');print('OFFICIAL INPUTS CAPTURED',len(files))
