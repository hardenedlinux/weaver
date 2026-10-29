"""Finite document fixtures only; not a production Gateway decoder/compiler."""
from pathlib import Path
import json,re,copy,hashlib,yaml
out=Path('proofs/evidence/routine-routing-config');org=Path('docs/40-49-admission-coordination/49-routine-routing-config/49.01-routine-routing-config.org')
def pairs(xs):
 d={}
 for k,v in xs:
  if k in d:raise ValueError('duplicate key')
  d[k]=v
 return d
class Strict(yaml.SafeLoader):pass
def mapping(loader,node,deep=False):return pairs([(loader.construct_object(k,deep=deep),loader.construct_object(v,deep=deep)) for k,v in node.value])
Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,mapping)
def read_yaml(s):
 if any(isinstance(e,yaml.AliasEvent) for e in yaml.parse(s)):raise ValueError('alias outside profile')
 return yaml.load(s,Loader=Strict)
def validate(x):
 assert type(x)==dict and set(x)=={'name','policyRef','budget','routines','routes'}
 assert x['name']=='support.resolve' and x['policyRef']=='governance.support'
 assert set(x['budget'])=={'domain','maxCostUnits'} and x['budget']['domain']=='original-task'
 cap=x['budget']['maxCostUnits'];assert type(cap)==int and cap>=0
 assert set(x['routines'])=={'resolve'} and set(x['routines']['resolve'])=={'inputContract','steps'}
 assert x['routines']['resolve']['inputContract']=='support.request'
 steps=x['routines']['resolve']['steps'];assert len(steps)==3
 ids=[s['id'] for s in steps];assert len(set(ids))==len(ids)
 seen=set();total=0
 for s in steps:
  kind=s['kind'];assert kind in ['tool','inference','response']
  common={'id','kind','after'}
  fields={'tool':{'capabilityRef','resultContract','maxInvocations','maxCostUnits'},'inference':{'routeRef','capabilityRequirements','responseContract','maxInvocations','maxCostUnits'},'response':{'responseContract'}}[kind]
  assert set(s)<=common|fields and fields<=set(s)
  assert set(s.get('after',[]))<=seen
  if kind!='response':
   assert type(s['maxInvocations'])==int and s['maxInvocations']==1
   assert type(s['maxCostUnits'])==int and s['maxCostUnits']>=0
   total+=s['maxCostUnits']*s['maxInvocations']
  if kind=='tool':assert s['capabilityRef']=='knowledge.search' and s['resultContract']=='knowledge.matches'
  if kind=='inference':assert s['routeRef'] in x['routes'] and set(s['capabilityRequirements'])=={'tool-calling','structured-output'}
  if kind in ['inference','response']:assert s['responseContract']=='support.reply'
  seen.add(s['id'])
 assert total<=cap
 assert set(x['routes'])=={'support.reply'}
 r=x['routes']['support.reply'];assert set(r)=={'candidates','objective','unknownOutcome'}
 assert r['candidates']==['reply-primary','reply-backup'] and r['objective']=='cost-with-quality-floor' and r['unknownOutcome']=='retain-reservation'
 return x
text=org.read_text();j=re.search(r'^#\+begin_src json[^\n]*\n(.*?)^#\+end_src',text,re.M|re.S).group(1);y=re.search(r'^#\+begin_src yaml[^\n]*\n(.*?)^#\+end_src',text,re.M|re.S).group(1)
a=validate(json.loads(j,object_pairs_hook=pairs));b=validate(read_yaml(y));assert a==b==json.loads((out/'example-expected.json').read_text())
checks=['json-yaml-decoded-data-equal','finite-dag-contract-and-allowance-valid']
def reject(name,f):
 try:f()
 except (ValueError,AssertionError,KeyError,yaml.YAMLError,TypeError):checks.append(name);return
 raise AssertionError('accepted '+name)
reject('duplicate-json-key',lambda:json.loads('{"name":1,"name":2}',object_pairs_hook=pairs))
reject('duplicate-yaml-key',lambda:read_yaml('name: a\nname: b'))
reject('executable-yaml-tag',lambda:read_yaml('!scheme "(send!)"'))
reject('yaml-alias-outside-profile',lambda:read_yaml('a: &a [1]\nb: *a'))
def altered(change):
 x=copy.deepcopy(a);change(x);return validate(x)
reject('unknown-authority-root',lambda:altered(lambda x:x.update(root=1)))
reject('boolean-is-not-cost',lambda:altered(lambda x:x['budget'].update(maxCostUnits=True)))
reject('unknown-node-field',lambda:altered(lambda x:x['routines']['resolve']['steps'][1].update(policyOverride='allow')))
reject('cycle-or-forward-reference',lambda:altered(lambda x:x['routines']['resolve']['steps'][0].update(after=['draft'])))
reject('sum-exceeds-routine-envelope',lambda:altered(lambda x:x['budget'].update(maxCostUnits=1)))
reject('unknown-route-reference',lambda:altered(lambda x:x['routines']['resolve']['steps'][1].update(routeRef='untrusted')))
reject('lost-response-contract',lambda:altered(lambda x:x['routines']['resolve']['steps'][1].pop('responseContract')))
reject('unknown-inline-credential',lambda:altered(lambda x:x.update(apiKey='untrusted')))
reject('implicit-boolean-is-not-objective',lambda:altered(lambda x:x['routes']['support.reply'].update(objective=read_yaml('on'))))
reject('dropped-required-capability',lambda:altered(lambda x:x['routines']['resolve']['steps'][1].update(capabilityRequirements=[])))
(out/'example-check.json').write_text(json.dumps(dict(checks=checks,count=len(checks),orgSha256=hashlib.sha256(org.read_bytes()).hexdigest(),canonicalExampleSha256=hashlib.sha256(json.dumps(a,sort_keys=True,separators=(',',':')).encode()).hexdigest(),boundary='JSON/YAML finite fixture; Scheme block and native compiler are not executed'),indent=2)+'\n')
print('PASS:',len(checks),'finite JSON/YAML/example checks; no native compiler claim')
