"""Finite authoring examples only: not native POO/Contracts or Gateway code."""
from pathlib import Path
import json,re,copy,yaml,hashlib
out=Path(__file__).parent
org=Path('docs/50-59-research-program/51-qualified-semantic-slice/51.02-configuration-and-authority.org')
def pairs(xs):
 d={}
 for k,v in xs:
  if type(k)!=str or k in d:raise ValueError('non-string or duplicate key')
  d[k]=v
 return d
def json_read(s):return json.loads(s,object_pairs_hook=pairs,parse_constant=lambda x:(_ for _ in ()).throw(ValueError(x)))
class Strict(yaml.SafeLoader):pass
def mapping(loader,node):return pairs([(loader.construct_object(k),loader.construct_object(v)) for k,v in node.value])
def integer(loader,node):
 if not re.fullmatch(r'0|[1-9][0-9]*',node.value):raise ValueError('unsigned decimal integer required')
 return int(node.value)
Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,mapping)
Strict.add_constructor('tag:yaml.org,2002:int',integer)
def yaml_read(s):
 for event in yaml.parse(s):
  if isinstance(event,yaml.AliasEvent) or getattr(event,'anchor',None) is not None:raise ValueError('aliases/anchors not admitted')
 if any(isinstance(t,yaml.tokens.TagToken) for t in yaml.scan(s)):raise ValueError('explicit tags not admitted')
 return yaml.load(s,Loader=Strict)
required={'routine','node','response','targets','ceiling-microcredits'}
optional={'extra-requirements','context-floor-tokens','extensions'}
def validate(x):
 assert type(x)==dict and required<=set(x)<=required|optional
 x=copy.deepcopy(x)
 for k,v in [('extra-requirements',[]),('context-floor-tokens',0),('extensions',{})]:x.setdefault(k,v)
 assert x['routine']=='support.resolve' and x['node']=='infer' and x['response']=='support.answer'
 assert type(x['targets'])==list and x['targets'] and len(set(x['targets']))==len(x['targets'])
 assert all(t in ['support.primary','support.private'] for t in x['targets'])
 assert type(x['extra-requirements'])==list and x['extra-requirements']==[] # finite registered fixture
 assert type(x['extensions'])==dict and x['extensions']=={} # no registered extension in fixture
 for k in ['ceiling-microcredits','context-floor-tokens']:assert type(x[k])==int and 0<=x[k]<=2**64-1
 return x
s=org.read_text();j=re.search(r'^#\+begin_src json\n(.*?)^#\+end_src',s,re.M|re.S).group(1);y=re.search(r'^#\+begin_src yaml\n(.*?)^#\+end_src',s,re.M|re.S).group(1)
a=validate(json_read(j));b=validate(yaml_read(y));assert a==b
checks=['finite-json-yaml-meaning-equality']
def reject(name,f):
 try:f()
 except (ValueError,AssertionError,TypeError,KeyError,yaml.YAMLError):checks.append(name);return
 raise AssertionError('unexpected acceptance: '+name)
def changed(k,v):x=copy.deepcopy(a);x[k]=v;return validate(x)
reject('duplicate-json-key',lambda:json_read('{"node":"infer","node":"release"}'))
reject('duplicate-yaml-key',lambda:yaml_read('node: infer\nnode: release'))
reject('yaml-explicit-tag',lambda:yaml_read('node: !!str infer'))
reject('yaml-anchor',lambda:yaml_read('targets: &a [support.primary]'))
reject('yaml-merge-alias',lambda:yaml_read('base: &a {node: infer}\nother: {<<: *a}'))
reject('unknown-authority-field',lambda:changed('origin','new-origin'))
reject('null-limit',lambda:changed('ceiling-microcredits',None))
reject('boolean-limit',lambda:changed('ceiling-microcredits',True))
reject('fraction-limit',lambda:changed('ceiling-microcredits',1.5))
reject('string-limit',lambda:changed('ceiling-microcredits','100'))
reject('negative-limit',lambda:changed('ceiling-microcredits',-1))
reject('overflow-limit',lambda:changed('ceiling-microcredits',2**64))
reject('changed-response-contract',lambda:changed('response','other.schema'))
reject('unknown-target',lambda:changed('targets',['unadmitted']))
reject('empty-target-list',lambda:changed('targets',[]))
reject('nondecimal-yaml-int',lambda:yaml_read('ceiling-microcredits: 0x10'))
x=copy.deepcopy(a)
for k in optional:del x[k]
assert validate(x)=={**a,'context-floor-tokens':0};checks.append('missing-optional-defaults')
assert min(90000,a['ceiling-microcredits'])==90000;checks.append('authored-ceiling-cannot-raise-original-reservation')
(out/'authoring-fixture.json').write_text(json.dumps(dict(status='PASS',checks=checks,count=len(checks),orgSha256=hashlib.sha256(org.read_bytes()).hexdigest(),boundary='Finite JSON/YAML fixture only; native Scheme and common compiler are not executed'),indent=2)+'\n')
print('PASS:',len(checks),'finite authoring checks; native compiler qualification not claimed')
