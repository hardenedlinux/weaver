from pathlib import Path
import subprocess,os,tempfile,time,json,hashlib
out=Path(__file__).parent.resolve()/'unsandboxed-diagnostic';out.mkdir(exist_ok=True);fixture=Path('proofs/evidence/committed-profile-binding/native-authoring.ss').resolve()
env=dict(os.environ,GERBIL_PATH=tempfile.mkdtemp(prefix='weaver-exit-diagnosis-'),GERBIL_LOADPATH='/Users/guangtao/ghq/github.com/tao3k/poo-flow/core/.gerbil/lib:/Users/guangtao/.gerbil/lib')
started=time.monotonic();events=[];sample=None;complete=None;gate=None
log=(out/'installed-diagnostic.log').open('w');p=subprocess.Popen(['gxi',str(fixture)],env=env,stdout=log,stderr=subprocess.STDOUT)
while True:
 elapsed=time.monotonic()-started;text=(out/'installed-diagnostic.log').read_text()
 if complete is None and 'NATIVE-AUTHORING-CHECKS-COMPLETE' in text:complete=elapsed;events.append({'at':elapsed,'event':'completion-output-observed'})
 if elapsed>=11 and sample is None and p.poll() is None:
  slog=(out/'sample-command.log').open('w');sample=subprocess.Popen(['/usr/bin/sample',str(p.pid),'1','10','-mayDie','-file',str(out/'installed-stack.txt')],stdout=slog,stderr=subprocess.STDOUT);events.append({'at':elapsed,'event':'own-process-sample-started'})
 if gate is None and (p.poll() is not None or elapsed>=15):gate=dict(exit=p.returncode,withinBudget=p.poll() is not None and elapsed<=15,at=elapsed)
 if p.poll() is not None or elapsed>=35:break
 time.sleep(.05)
log.close();sampleExit=None
if sample is not None:
 try:sampleExit=sample.wait(timeout=15)
 except subprocess.TimeoutExpired:sampleExit='still-running'
r=dict(args=['gxi',str(fixture)],pid=p.pid,nativeAcceptanceBudgetSeconds=15,gate=gate,diagnosticObservationLimitSeconds=35,observedProcessExit=p.poll(),seconds=round(time.monotonic()-started,3),completionOutputAtSeconds=complete,events=events,sampleExit=sampleExit,stackAvailable=(out/'installed-stack.txt').exists(),sourceSha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),forcedNativeExit=False,qualification='Late natural exit during post-failure diagnosis cannot satisfy unchanged 15-second acceptance gate')
(out/'installed-diagnostic.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({k:r[k] for k in ['pid','gate','observedProcessExit','seconds','stackAvailable']}))
