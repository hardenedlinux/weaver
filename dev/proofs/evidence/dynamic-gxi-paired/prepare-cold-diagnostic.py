from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import subprocess,json,os,hashlib,re
p=Path(__file__).parent;root=Path('.data/dynamic-gxi-paired-20261020').resolve();rows=json.loads((p/'official-object-build.json').read_text());flags=json.loads((p/'official-compiler-options.json').read_text())['options'];env=dict(os.environ);env.pop('SDKROOT',None)
def link(row):
 target=root/'cold-diagnostic-images'/(row['module']+'.o1');target.parent.mkdir(parents=True,exist_ok=True)
 args=['/opt/homebrew/bin/gcc-16',*flags['FLAGS_OPT'],*flags['FLAGS_DYN'],'-Wl,-random_uuid',row['object'],'-isysroot','/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk','-lSystem','-o',str(target)]
 with target.with_suffix('.link.log').open('w') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 assert r.returncode==0
 h=subprocess.check_output(['/usr/bin/otool','-l',str(target)],text=True);uuid=re.search(r'uuid ([A-Fa-f0-9-]+)',h).group(1)
 return dict(path=str(target),uuid=uuid,sha256=hashlib.sha256(target.read_bytes()).hexdigest(),object=row['object'],objectSha256=row['objectSha256'],args=args)
with ThreadPoolExecutor(max_workers=3) as pool:images=list(pool.map(link,rows))
old={r['uuid'] for f in ['images.json','uuid-images.json'] for r in json.loads((p/f).read_text())};assert len(images)==98 and len({r['uuid'] for r in images})==98 and not ({r['uuid'] for r in images}&old)
(p/'cold-diagnostic-images.json').write_text(json.dumps(images,indent=2)+'\n');print('COLD DIAGNOSTIC GENERATION',len(images))
