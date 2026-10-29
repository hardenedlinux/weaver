from pathlib import Path
import subprocess,os,json,hashlib,time,tempfile
out=Path(__file__).parent;core=Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/core')
script='''(import :clan/poo/object (only-in :clan/poo/mop element?) :core/modules/json-schema/contracts)
(def bounded (schema-value-contract 'weaver/probe '((type . "integer") (minimum . 0) (maximum . 10))))
(unless (and (element? bounded 7) (not (element? bounded 11))) (error "native bounded contract failed"))
(display "NATIVE-CONTRACT-PROBE-PASS\\n")
'''
(out/'native-probe.ss').write_text(script)
args=['gxi',str(out/'native-probe.ss')];t=time.monotonic()
env=dict(os.environ,GERBIL_PATH=tempfile.mkdtemp(prefix='weaver-native-profile-'),GERBIL_LOADPATH=str(core/'.gerbil/lib')+':/Users/guangtao/.gerbil/lib')
with (out/'native-probe.log').open('w') as log:
 try:c=subprocess.run(args,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=15).returncode
 except subprocess.TimeoutExpired:c=124
r=dict(args=args,exit=c,seconds=round(time.monotonic()-t,3),watchdogSeconds=15,gerbilPath=env['GERBIL_PATH'],loadpath=env['GERBIL_LOADPATH'],scope='Installed compiled Core value-contract import/behavior probe; not exact-source native build or Gateway compiler parity',sourceSha256=hashlib.sha256((out/'native-probe.ss').read_bytes()).hexdigest())
(out/'native-probe.json').write_text(json.dumps(r,indent=2)+'\n');print('native probe exit',c)

raise SystemExit(c)
