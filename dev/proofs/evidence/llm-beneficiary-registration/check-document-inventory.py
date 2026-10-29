from pathlib import Path
import re, subprocess
root=Path.cwd(); docs=[root/'README.org',*sorted((root/'docs').rglob('*.org')),*sorted((root/'specs').rglob('*.org'))]
assert len(docs)==153,len(docs)
nlinks=0
for p in docs:
 s=p.read_text();assert s.isascii(),p
 for target in re.findall(r'\[\[file:([^\]]+)\]',s):
  target=target.split('::')[0];assert (p.parent/target).exists(),(p,target);nlinks+=1
 assert len(re.findall(r'^#\+begin_',s,re.M|re.I))==len(re.findall(r'^#\+end_',s,re.M|re.I)),p
diagrams=[p for p in (root/'docs').rglob('*.d2') if p.parent.name!='lib'];assert len(diagrams)==64
for p in diagrams:
 assert p.read_text().isascii(),p
 assert p.with_suffix('.svg').is_file(),p
s=(root/'docs/architecture/01-reference-comparison.org').read_text()
repos={
'ag':(root/'.data/agentgateway','955d56fae09b45f3cb8e85e797dbb1eb06134f77'),
'pf':(Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow'),'a74fc2fd63437252175b5a67649ee54b886d3bf4'),
'pc':(Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/core'),'80e2e74022c9c4053445475402856c5f369aec48'),
'ai':(Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/packages/lambda-aitia'),'cbf3f6861ef7cf66d8d02aaf71b1c89630eaf7fc'),
'cp':(Path('/private/tmp/weaver-cedar-poo-spec-reference-20261018'),'c8d1a0641120cf65e299e8a98f9fe7666ca96ab5')}
repos.update({
'pc31':(Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/core'),'377761072f2e8e39ae03ee26027d1fa5ad80b018'),
'cs31':(Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/packages/proofs/lean/.lake/packages/Cedar'),'e9fa9c1e6b636f29b0897d8706bd7aa5eaf06f9a'),
'cs34':(Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/packages/proofs/lean/.lake/packages/Cedar'),'017c35c3d1f856a0f8b62a66660ee6628870bbcf'),
'lp':(Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/packages/proofs/lean/.lake/packages/LeanPoo'),'ccb94dc44d874050dc8a8ede692bb2afac55ea37')})
refs=re.findall(r'\[\[(ag|pf|pc|ai|cp|cs31|cs34|lp|pc31):([^\]]+)\]',s)
for alias,path in refs:
 repo,sha=repos[alias];subprocess.run(['git','-C',str(repo),'cat-file','-e',sha+':'+path],check=True)
validation='\n'.join(p.read_text() for p in docs)
for prefix,expected in [('SF',12),('AC',12),('R',14),('Z',10),('G',10),('CX',18),('FM',12)]:
 ids=re.findall(r'^\| ('+prefix+r'\d+)\b[^|]*\|',validation,re.M);assert len(ids)==expected,(prefix,len(ids));assert len(set(ids))==expected
print(f'PASS: {len(docs)} English Org documents; {nlinks} local links; {len(refs)} pinned Git source targets; acceptance registers complete; {len(diagrams)} D2/SVG pairs')
