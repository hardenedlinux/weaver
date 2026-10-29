from pathlib import Path
import json,subprocess,time,hashlib
out=Path(__file__).parent
# The retained successful command uses current generated object paths. Its
# platform SDK/runtime flags must follow the Gambit and other libraries.
args=json.loads((out/'link-system-library.json').read_text())['args']
inputs={x:hashlib.sha256(Path(x).read_bytes()).hexdigest() for x in args if x.endswith('.o') and Path(x).is_file()}
t=time.monotonic()
with (out/'relink-replay.log').open('w') as f:r=subprocess.run(args,stdout=f,stderr=subprocess.STDOUT)
(out/'relink-replay.json').write_text(json.dumps(dict(args=args,objectInputs=inputs,exit=r.returncode,seconds=round(time.monotonic()-t,3)),indent=2)+'\n')
raise SystemExit(r.returncode)
