from pathlib import Path
import os,subprocess,hashlib,json,time,difflib
out=Path(__file__).parent;root=Path('.data/dynamic-gxi-exit-20261020').resolve();origin=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current/src/std');source=root/'narrow-source/std';lib=root/'lib-narrow';lib.mkdir(exist_ok=True)
names=['text/parser/ll1.ss','encoding/json/env.ss','encoding/json/reader.ss','encoding/json/writer.ss','encoding/json/io.ss','encoding/json/util.ss','encoding/json/api.ss','encoding/json.ss'];records=[];patch=[]
for name in names:
 p=source/name;p.parent.mkdir(parents=True,exist_ok=True);old=(origin/name).read_text();new=old
 if name in ['encoding/json/reader.ss','encoding/json/writer.ss','encoding/json/io.ss','encoding/json/util.ss']:new=new.replace(':std/io\n',':std/io/interface\n')
 if name=='text/parser/ll1.ss':new=new.replace(':std/io\n',':std/io/interface\n  :std/io/bio/api\n')
 p.write_text(new);records.append(dict(path=name,original=str(origin/name),copy=str(p),originalSha256=hashlib.sha256(old.encode()).hexdigest(),candidateSha256=hashlib.sha256(new.encode()).hexdigest(),changed=old!=new));patch.extend(difflib.unified_diff(old.splitlines(keepends=True),new.splitlines(keepends=True),fromfile='installed/std/'+name,tofile='isolated/std/'+name))
(source/'gerbil.pkg').write_text('(package: std prelude: :gerbil/base)\n');(out/'stdlib-import-only.patch').write_text(''.join(patch));(out/'stdlib-source-snapshot.json').write_text(json.dumps(records,indent=2)+'\n')
build='''(import :gerbil/compiler :gerbil/expander)
(def source (getenv "WEAVER_STD_SOURCE"))
(def originals (current-expander-module-import))
(def names 'NAMES)
(def (local-import path (reload? #f))
 (let* ((datum (syntax-e path)) (name (and (symbol? datum) (symbol->string datum)))
        (local (and name (string-prefix? ":std/" name) (member (string-append (substring name 5 (string-length name)) ".ss") names) (path-expand (string-append (substring name 5 (string-length name)) ".ss") source))))
   (originals (or local path) reload?)))
(parameterize ((current-expander-context (make-top-context)) (current-expander-module-import local-import))
 (for-each (lambda (name)
  (displayln "COMPILE-START std/" name) (force-output)
  (compile-module (path-expand name source) [output-dir: (getenv "WEAVER_STD_LIB") invoke-gsc: #t keep-scm: #t])
  (execute-pending-compile-jobs!)
  (displayln "COMPILE-DONE std/" name) (force-output)) names))
(displayln "NARROW-STDLIB-BUILD-COMPLETE")
'''.replace('NAMES','('+ ' '.join(json.dumps(n) for n in names) +')')
(out/'compile-narrow.ss').write_text(build)
env=dict(os.environ,WEAVER_STD_SOURCE=str(source),WEAVER_STD_LIB=str(lib),GERBIL_PATH=str(root/'narrow-build-env'),GERBIL_LOADPATH=str(lib));Path(env['GERBIL_PATH']).mkdir(exist_ok=True);env.pop('SDKROOT',None)
t=time.monotonic();args=['gxi',str(out/'compile-narrow.ss')]
with (out/'narrow-build.log').open('w') as f:
 p=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT);print('stdlib builder',p.pid,flush=True);c=p.wait()
(out/'narrow-build.json').write_text(json.dumps(dict(args=args,exit=c,seconds=round(time.monotonic()-t,3),changedFiles=5,scope='Import-owner narrowing only; all function and macro bodies byte-identical'),indent=2)+'\n');print('STDLIB BUILD',c,flush=True)
raise SystemExit(c)
