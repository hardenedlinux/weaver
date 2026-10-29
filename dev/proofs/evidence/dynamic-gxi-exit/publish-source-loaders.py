from pathlib import Path
import re,json,hashlib
out=Path(__file__).parent
if (out/"SHA256SUMS").exists() and (out/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation is immutable; reproduce in fresh isolation and evidence directories.")
root=Path('.data/dynamic-gxi-exit-20261020').resolve();overlay=root/'source-loaders';overlay.mkdir(exist_ok=True)
installed=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current/lib')
native=root/'lib-native';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
# Closed, deliberately restrictive recognizer. No general Scheme evaluation,
# rewriting, imports, arbitrary declarations or procedure bodies are admitted.
def recognize(text):
 tokens=re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^\s()]+',text);at=0
 def read():
  nonlocal at
  if at>=len(tokens):raise ValueError('eof')
  t=tokens[at];at+=1
  if t=='(':
   xs=[]
   while at<len(tokens) and tokens[at]!=')':xs.append(read())
   if at>=len(tokens):raise ValueError('unclosed')
   at+=1;return xs
  if t==')':raise ValueError('unexpected close')
  return t
 forms=[]
 while at<len(tokens):forms.append(read())
 if len(forms)!=2 or forms[0]!=['declare',['block'],['standard-bindings'],['extended-bindings']]:return None
 deps=[]
 def stub(form):
  if not isinstance(form,list) or not form:return False
  if form[0]=='begin':return all(stub(x) for x in form[1:])
  if len(form)==2 and form[0]=='load-module' and isinstance(form[1],str) and form[1].startswith('"'):
   name=json.loads(form[1]);
   if not re.fullmatch(r'[A-Za-z0-9_./~+*-]+',name):return False
   deps.append(name);return True
  return False
 return deps if stub(forms[1]) else None
rows=[]
for label,lib in [('installed',installed),('rebuilt',native)]:
 for src in sorted(lib.rglob('*.scm')):
  if '~' in src.name or not src.with_suffix('.ssi').is_file():continue
  try:deps=recognize(src.read_text())
  except (ValueError,UnicodeError,json.JSONDecodeError):deps=None
  if deps is None:continue
  dest=overlay/src.relative_to(lib)
  # Rebuilt source owns any overlapping module; no installed object is copied.
  dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(src.read_bytes())
  interface=src.with_suffix('.ssi');publishedInterface=dest.with_suffix('.ssi');publishedInterface.write_bytes(interface.read_bytes())
  rows.append(dict(module=str(src.relative_to(lib))[:-4],owner=label,source=str(src),published=str(dest),sha256=sha(src),interface=str(interface),publishedInterface=str(publishedInterface),interfaceSha256=sha(interface),loads=deps,nativeStubCandidates=[str(p) for p in src.parent.glob(src.stem+'.o[0-9]*') if p.is_file()]))
assert rows
(out/'source-loader-publication.json').write_text(json.dumps(dict(overlay=str(overlay),rows=rows,recognizer='exact declare + recursive begin/load-module only; no body rewriting',bodyPolicy='All ~0/~1 and foreign objects retained under ordinary dynamic loader'),indent=2)+'\n');print('PUBLISHED',len(rows),'byte-identical source loader stubs')
