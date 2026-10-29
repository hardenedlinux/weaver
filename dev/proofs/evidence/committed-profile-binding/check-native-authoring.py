from pathlib import Path
import subprocess,os,json,hashlib,time,tempfile
out=Path(__file__).parent;core=Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/core')
args=['gxi',str(out/'native-authoring.ss')];t=time.monotonic()
env=dict(os.environ,GERBIL_PATH=tempfile.mkdtemp(prefix='weaver-native-profile-'),GERBIL_LOADPATH=str(core/'.gerbil/lib')+':/Users/guangtao/.gerbil/lib')
with (out/'native-authoring.log').open('w') as log:
 try:c=subprocess.run(args,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=15).returncode
 except subprocess.TimeoutExpired:c=124
r=dict(args=args,exit=c,seconds=round(time.monotonic()-t,3),watchdogSeconds=15,gerbilPath=env['GERBIL_PATH'],loadpath=env['GERBIL_LOADPATH'],scope='Installed compiled Core value-contract and actual Gerbil JSON decoder checks; not exact-source native build, normalization or YAML parity',sourceSha256=hashlib.sha256((out/'native-authoring.ss').read_bytes()).hexdigest())
(out/'native-authoring.json').write_text(json.dumps(r,indent=2)+'\n');print('native probe exit',c)

raise SystemExit(c)
