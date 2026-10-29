from pathlib import Path
import re,json,hashlib
out=Path(__file__).parent;parts=[];records=[]
for name in ['LlmRouting','RoutineRoutingConfig','SemanticGatewaySlice','CommittedSemanticProfile']:
 p=Path('proofs/qunit')/(name+'.qnt');s=p.read_text();n=0
 if name!='CommittedSemanticProfile':
  lines=s.splitlines(keepends=True);n=sum(bool(re.match(r'^  run ',line)) for line in lines);s=''.join('\n' if re.match(r'^  run ',line) else line for line in lines)
 s=s.replace(' from "./LlmRouting"','').replace(' from "./RoutineRoutingConfig"','').replace(' from "./SemanticGatewaySlice"','');parts.append(s)
 records.append(dict(source=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),omittedAncestorRunDeclarations=n))
(out/'bundle.qnt').write_text('\n'.join(parts));(out/'bundle-certificate.json').write_text(json.dumps(records,indent=2)+'\n')
assert records[0]['omittedAncestorRunDeclarations']==32 and records[1]['omittedAncestorRunDeclarations']==32 and records[2]['omittedAncestorRunDeclarations']==35
print('PASS: exact ancestor declarations retained except 99 historical run declarations; local import paths removed')
