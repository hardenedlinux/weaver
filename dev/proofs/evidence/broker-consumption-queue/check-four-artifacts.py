"""Check named design references against the actual formal and diagram sources."""
from pathlib import Path
import json,re
root=Path.cwd();out=root/'proofs/evidence/broker-consumption-queue'
doc=(root/'docs/30-39-assurance/37-broker-consumption-queue/37.01-consumption-to-final-queue.org').read_text()
q=(root/'proofs/qunit/BrokerConsumptionQueue.qnt').read_text()
l=(root/'proofs/lean/BrokerConsumptionQueue.lean').read_text()
d=(root/'docs/30-39-assurance/37-broker-consumption-queue/37.02-broker-consumption-queue.d2').read_text()
records=[]
for line in doc.splitlines():
 if not re.match(r'^\| BQ\d+ ',line):continue
 cells=[c.strip() for c in line.split('|')[1:-1]]
 assert len(cells)==5,cells
 contract,rule,quint,lean,node=cells
 qnames=quint.split('; ');lnames=lean.split('; ')
 for name in qnames:assert re.search(r'\b(?:run|val) '+re.escape(name)+r'\b',q),(contract,name)
 for name in lnames:
  assert re.search(r'\b(?:theorem|def) '+re.escape(name)+r'\b',l),(contract,name)
 parent,child=node.split('.');assert re.search(r'^'+parent+r':',d,re.M) and re.search(r'^  '+child+r':',d,re.M),(contract,node)
 records.append(dict(contract=contract,orgRule=rule,quint=qnames,lean=lnames,d2=node))
assert len(records)==10
(out/'four-artifact-check.json').write_text(json.dumps(dict(status='pass',boundary='Named-reference consistency, not semantic equivalence or native extraction',contracts=records),indent=2)+'\n')
print('PASS: 10 Org / Quint / Lean / core D2 correspondence rows')
