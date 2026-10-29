from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import json,subprocess,os,re,hashlib
out=Path(__file__).parent;root=Path('.data/native-image-closure-20261020').resolve();assert not (out/'SHA256SUMS').exists();rows=json.loads((out/'objects.json').read_text());by={r['module']:r for r in rows};groups=json.loads((out/'partition.json').read_text());flags=json.loads((out/'compiler-options.json').read_text())['options'];link=json.loads((out/'link-profile.json').read_text());env=dict(os.environ);env.pop('SDKROOT',None);sha=lambda f:hashlib.sha256(Path(f).read_bytes()).hexdigest()
assert all(sha(r['object'])==r['objectSha256'] for r in rows)
def one(task):
 gen,number,members=task;image=root/'launcher-cold'/f'g{gen}'/'physical'/f'image-{number}.o1';image.parent.mkdir(parents=True,exist_ok=True);args=['/opt/homebrew/bin/gcc-16',*flags['FLAGS_OPT'],*flags['FLAGS_DYN'],'-Wl,-random_uuid',*[by[n]['object'] for n in members],'-isysroot',link['sdk'],'-lSystem','-o',str(image)]
 with image.with_suffix('.link.log').open('w') as f:p=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 assert p.returncode==0;headers=subprocess.check_output(['/usr/bin/otool','-l',str(image)],text=True);assert '__mod_init_func' not in headers and '__mod_term_func' not in headers;uuid=re.search(r'uuid ([A-Fa-f0-9-]+)',headers).group(1);symbols=subprocess.check_output(['/usr/bin/nm','-gU',str(image)],text=True);assert {l.split()[-1] for l in symbols.splitlines() if 'LNK_' in l}=={by[n]['entry'] for n in members};aliases=[]
 for name in members:
  path=root/'launcher-cold'/f'g{gen}'/'aliases'/(name+'.o1');path.parent.mkdir(parents=True,exist_ok=True);os.link(image,path);aliases.append(str(path))
 return dict(generation=gen,group=number,path=str(image),uuid=uuid,sha256=sha(image),aliases=aliases,args=args)
with ThreadPoolExecutor(max_workers=3) as pool:images=list(pool.map(one,[(g,n,m) for g in range(4) for n,m in enumerate(groups)]))
old={im['uuid'] for im in json.loads((out/'images.json').read_text())};assert len(images)==16 and len({im['uuid'] for im in images})==16 and not(old&{im['uuid'] for im in images});(out/'launcher-cold-images.json').write_text(json.dumps(images,indent=2)+'\n');print('PREPARED FRESH ORDINARY LAUNCHER',len(images))
