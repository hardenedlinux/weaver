from pathlib import Path
import json,hashlib,subprocess
p=Path(__file__).parent;stable=json.loads((p/'images.json').read_text());random=json.loads((p/'uuid-images.json').read_text());assert len(stable)==len(random)==420
# Fresh links are content-identical across the stable family, while random UUIDs
# are unique. Verify executable instruction bytes for each original image layout.
layout=lambda r:(r['kind'],tuple(r['entries']))
a={layout(r):r for r in stable};b={layout(r):r for r in random};assert a.keys()==b.keys()
rows=[]
for key in a:
 def text(r):
  data=subprocess.check_output(['/usr/bin/otool','-s','__TEXT','__text',r['path']],text=True).splitlines()[1:]
  return hashlib.sha256('\n'.join(data).encode()).hexdigest()
 x=text(a[key]);y=text(b[key]);assert x==y,key
 rows.append(dict(kind=key[0],entries=list(key[1]),stable=a[key]['path'],random=b[key]['path'],textSha256=x,equal=True))
assert len({r['uuid'] for r in random})==420
assert len({r['inode'] for r in stable+random})==840
(p/'identity-audit.json').write_text(json.dumps(dict(stableImages=420,stableUUIDs=len({r['uuid'] for r in stable}),randomImages=420,randomUUIDs=420,distinctInodes=840,executableLayouts=rows,scope='Text-byte equality across UUID variants for each unique same-object layout; not a compiler correctness or whole-host cache-cold proof'),indent=2)+'\n')
print('IDENTITY AND TEXT AUDIT PASS',len(rows))
