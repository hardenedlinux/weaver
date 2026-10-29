"""Check evidence correspondence; no Gateway behavior is implemented here."""
from pathlib import Path
import json,hashlib,re
root=Path.cwd();out=Path(__file__).parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
r=json.loads((out/'clean-proof-receipt.json').read_text());assert len(r['modules'])==12
for m in r['modules']:
 assert m['exit']==0 and m['noSorryAx']
 assert sha(Path(m['source']))==m['sourceSha256']
 compiled=Path(r['compiledDirectory'])/(m['module']+'.olean');assert sha(compiled)==m['compiledSha256']
 text=(out/(m['module']+'.log')).read_text();assert 'error:' not in text and 'sorryAx' not in text
assert r['modules'][-1]['module']=='SemanticGatewaySlice' and r['modules'][-1]['printedDeclarations']==19
q=Path('proofs/qunit/SemanticGatewaySlice.qnt').read_text();tests=re.findall(r'^  run (\w+Test)=',q,re.M);assert len(tests)==35
faults=[t for t in tests if t.endswith('CounterexampleTest')];assert len(faults)==6
step=re.search(r'  action step:bool=(.*)',q).group(1);assert 'unsafe' not in step
api=json.loads((out/'api-commands.json').read_text());assert len(api)==14 and all(x['exit']==0 for x in api)
passed=[t for record in api for t in record.get('passed',[])];assert len(passed)==35 and set(passed)==set(tests)
assert all(record['typedIrUnchanged'] for record in api if record['label'].startswith('api-controls-'))
inv=json.loads((out/'api-invocation.json').read_text());assert inv['exit']==0 and inv['expectedControls']==35
for name,h in inv['inputs'].items():assert sha(root/name)==h
parts=[]
for row in json.loads((out/'bundle-certificate.json').read_text()):
 p=Path(row['source']);assert sha(p)==row['sha256'];s=p.read_text()
 if row['omittedAncestorRunDeclarations']:
  assert len(re.findall(r'^  run ',s,re.M))==row['omittedAncestorRunDeclarations']
  s=''.join('\n' if re.match(r'^  run ',line) else line for line in s.splitlines(keepends=True))
 parts.append(s.replace(' from "./LlmRouting"','').replace(' from "./RoutineRoutingConfig"',''))
assert '\n'.join(parts)==(out/'bundle.qnt').read_text()
sim=json.loads((out/'simulation.json').read_text());assert sim['status']=='ok' and sim['errors']==[]
assert json.loads((out/'simulation-command.json').read_text())['exit']==0
assert json.loads((out/'authoring-fixture.json').read_text())['count']==19
review=json.loads((out/'source-currentness.json').read_text());assert len(review)==16 and all(x['headMatches'] and x['workingMatches'] for x in review)
assert len(json.loads((out/'historical-manifests.json').read_text()))==46
p=root/'docs/50-59-research-program/51-qualified-semantic-slice'
assert 'PASS: exported 6 Org documents' in (out/'org-export.log').read_text()
org='\n'.join(x.read_text() for x in p.glob('*.org'));lean=Path('proofs/lean/SemanticGatewaySlice.lean').read_text()
rows=[('constructed_refinement','forgedProfileCannotQueueTest'),('actual_dispatch_preserves_constructed_parent','queueHasNoExternalSendTest'),('actual_uses_share_registered_contract','forgedOriginCannotQueueTest'),('actual_source_claim_not_recreated','lostReplyCannotRetryTest'),('inherited_account_capacity','unknownRefundCounterexampleTest')]
for theorem,test in rows:assert theorem in org and ('theorem '+theorem) in lean and test in tests
s=(p/'51.06-semantic-gateway-slice.d2').read_text();assert all(x not in s for x in ['v4.34','202610','SHA256','19 declarations','35 controls'])
assert 'tala' in (out/'d2-render.log').read_text().lower() or 'success' in (out/'d2-render.log').read_text().lower()
result=dict(status='PASS',freshLeanDeclarations=19,freshCompiledModules=12,guardedQuintControls=29,deliberateFaultControls=6,officialPhases=14,authoringFixtureChecks=19,priorSeals=46,sourceMatches=16,traceabilityRows=rows,nativeQualification=False)
(out/'checkpoint-check.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS: 19 Lean declarations / clean 12-module closure; 35 Quint controls; 19 finite authoring checks; four-artifact correspondence; native qualification pending')
