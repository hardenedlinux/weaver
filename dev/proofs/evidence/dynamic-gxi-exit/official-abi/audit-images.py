from pathlib import Path
import json,subprocess,hashlib
out=Path(__file__).parent;plan=json.loads((out.parent/'official-dynamic-images.json').read_text());objects=json.loads((out.parent/'official-object-build.json').read_text());byModule={r['module']:r for r in objects};headers=out/'image-headers';headers.mkdir(exist_ok=True);rows=[]
for image in plan['images']:
 p=Path(image['image']);text=subprocess.check_output(['/usr/bin/otool','-l',str(p)],text=True);assert '__mod_init_func' not in text and '__mod_term_func' not in text
 (headers/(image['group'].replace('/','-')+'.txt')).write_text(text)
 symbols=subprocess.check_output(['/usr/bin/nm','-gU',str(p)],text=True);actual={line.split()[-1] for line in symbols.splitlines() if 'LNK_' in line};expected=set();moduleRows=[]
 for alias in image['aliases']:
  a=Path(alias);assert a.stat().st_ino==p.stat().st_ino and a.stat().st_dev==p.stat().st_dev
  name=str(a.relative_to(Path('.data/dynamic-gxi-exit-20261020/dynamic-images-official').resolve()))[:-3];r=byModule[name];source=Path(r['source']);assert hashlib.sha256(source.read_bytes()).hexdigest()==r['sourceSha256']
  original=source.with_suffix('.o1');oldSymbols=subprocess.check_output(['/usr/bin/nm','-gU',str(original)],text=True);entry={line.split()[-1] for line in oldSymbols.splitlines() if 'LNK_' in line};assert len(entry)==1,(name,entry);assert not expected.intersection(entry),(name,entry);expected.update(entry);moduleRows.append(dict(module=name,entry=next(iter(entry)),sourceSha256=r['sourceSha256'],originalNative=str(original)))
 assert expected==actual,(image['group'],expected-actual,actual-expected)
 rows.append(dict(group=image['group'],members=moduleRows,entrySymbols=sorted(actual),noCInitOrTermSections=True,inodeAliases=len(image['aliases']),imageSha256=hashlib.sha256(p.read_bytes()).hexdigest()))
(out/'image-entry-audit.json').write_text(json.dumps(rows,indent=2)+'\n');print('IMAGE ENTRY AUDIT PASS',sum(len(r['members']) for r in rows),'distinct original lazy entries in',len(rows),'images')
