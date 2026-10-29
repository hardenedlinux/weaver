"""Observe the same bounded native workload; never force a success exit."""
from pathlib import Path
import subprocess,tempfile,os,json,time,selectors,hashlib
out=Path(__file__).parent;script=out/'native-authoring.ss';args=['gxi',str(script)]
env=dict(os.environ,GERBIL_PATH=tempfile.mkdtemp(prefix='weaver-native-observed-'),GERBIL_LOADPATH='/Users/guangtao/ghq/github.com/tao3k/poo-flow/core/.gerbil/lib:/Users/guangtao/.gerbil/lib')
started=time.monotonic();p=subprocess.Popen(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);selector=selectors.DefaultSelector();selector.register(p.stdout,selectors.EVENT_READ);events=[];buffer=b'';completeAt=None;sampled=False;code=None
with (out/'native-observed.log').open('wb') as log:
 while True:
  elapsed=time.monotonic()-started
  if elapsed>15:p.kill();p.wait(timeout=3);code=124;break
  if completeAt is not None and elapsed>10 and p.poll() is None and not sampled:
   sampled=True
   try:subprocess.run(['/usr/bin/sample',str(p.pid),'1','1','-file',str(out/'native-post-output.sample.txt')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=3)
   except (OSError,subprocess.TimeoutExpired):pass
  for key,_ in selector.select(.1):
   chunk=os.read(key.fileobj.fileno(),65536)
   if not chunk:selector.unregister(key.fileobj);continue
   log.write(chunk);log.flush();buffer+=chunk
   while b'\n' in buffer:
    line,buffer=buffer.split(b'\n',1);text=line.decode(errors='replace');events.append(dict(seconds=round(time.monotonic()-started,3),line=text))
    if text=='NATIVE-AUTHORING-CHECKS-COMPLETE':completeAt=time.monotonic()-started
  if p.poll() is not None and not selector.get_map():code=p.returncode;break
r=dict(args=args,exit=code,watchdogSeconds=15,seconds=round(time.monotonic()-started,3),completionOutputAtSeconds=completeAt,events=events,sampleAttempted=sampled,sampleAvailable=(out/'native-post-output.sample.txt').exists(),sourceSha256=hashlib.sha256(script.read_bytes()).hexdigest(),qualification='Diagnostic run only; an isolated success does not resolve the prior unexplained timeout')
(out/'native-observed.json').write_text(json.dumps(r,indent=2)+'\n');print('native diagnostic',code,'completion output at',None if completeAt is None else round(completeAt,3),'seconds',flush=True)

raise SystemExit(code or 0)
