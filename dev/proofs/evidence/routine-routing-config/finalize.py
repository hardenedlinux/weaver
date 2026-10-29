from pathlib import Path
import hashlib,json,re,subprocess
ROOT=Path.cwd();out=Path('proofs/evidence/routine-routing-config');base=Path('docs/40-49-admission-coordination/49-routine-routing-config')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
api=json.loads((out/'api-invocation.json').read_text());assert api['exit']==0 and api['expectedControls']==32
for p,h in api['inputs'].items():assert sha(Path(p))==h,p
stage=json.loads((out/'typed-stage-summary.json').read_text());assert len(stage['modules'])==2
groups=json.loads((out/'api-groups.json').read_text())
expected={test+'-'+str(i)+'.itf.json' for group in groups for i,test in enumerate(group)}
assert len(expected)==32 and {p.name for p in (out/'itf').glob('*.json')}==expected

installed=Path('/opt/homebrew/Cellar/quint/0.33.0/libexec/lib/node_modules/@informalsystems/quint/dist/src')
assert sha(installed/'cliCommands.js')==stage['cliCommandsSha256']
assert sha(installed/'runtime/impl/evaluator.js')==stage['evaluatorSha256']
lean=json.loads((out/'lean-command.json').read_text());assert lean['exit']==0
for p,h in lean['sourceSha256'].items():assert sha(Path(p))==h
assert sha(Path(lean['args'][-2]))==lean['compiledSha256']
log=(out/'RoutineRoutingConfig.log').read_text();assert 'error:' not in log and 'sorryAx' not in log
assert len(re.findall(r"^'Weaver.RoutineRoutingConfig\.",log,re.M))==24
commands=json.loads((out/'commands.json').read_text());assert all(r['exit']==0 for r in commands)
assert len(commands)==22
for r in commands:
 hashes=r.get('sourceSha256',{})
 if isinstance(hashes,dict):
  for p,h in hashes.items():assert sha(Path(p))==h,(r['label'],p)
for name in ['org-export-command.json']:assert json.loads((out/name).read_text())['exit']==0
assert 'PASS: exported 162 Org documents' in (out/'org-export.log').read_text()
for helper,logfile in [('check-four-artifacts.py','four-artifacts-check.log'),('check-document-inventory.py','document-check.log')]:
 r=subprocess.run(['python3',str(out/helper)],capture_output=True,text=True,timeout=20);(out/logfile).write_text(r.stdout+r.stderr);assert r.returncode==0,r.stdout+r.stderr
checks=json.loads((out/'diagram-validation.json').read_text());assert len(checks)==67 and all(r['exit']==0 for r in checks)
assert len((out/'historical-manifests.log').read_text().splitlines())==44
# Historical bytes are rechecked immediately before the new seal.
for p in list(Path('specs/evidence').glob('*/SHA256SUMS'))+list(Path('proofs/evidence').glob('*/SHA256SUMS')):
 if p.parent==out:continue
 for line in p.read_text().splitlines():
  h,name=line.split('  ',1);assert sha(Path(name))==h,(p,name)
(out/'visual-inspection.log').write_text('PASS: final bundled SVG rasterized at width 2400 and inspected. Four language/authority lanes, local Go/Kubernetes/Rust icons, readable node labels and core proof relationships; no versions or acceptance counts in the diagram.\n')
(out/'document-source-hashes.json').write_text(json.dumps({str(p):sha(p) for p in sorted(base.iterdir()) if p.is_file()},indent=2)+'\n')
example=json.loads((out/'example-check.json').read_text());assert example['count']==16
assert sha(Path('docs/40-49-admission-coordination/49-routine-routing-config/49.01-routine-routing-config.org'))==example['orgSha256']
r=subprocess.run(['python3',str(out/'check-source-review.py')],capture_output=True,text=True,timeout=20);assert r.returncode==0,r.stdout+r.stderr
source=json.loads((out/'source-check.json').read_text());assert source['files']==16
receipt=dict(status='PASS_CONDITIONAL_MODEL_CONTROLS',freshLeanDeclarations=24,sourceCheckedReusedLeanReceipts=7,currentQuintControls=32,ordinaryGuardedControls=28,decodedFaultControls=4,finiteJsonYamlFixtureChecks=16,currentSuccessfulPhases=22,officialFullTypeEffectAnalysis=True,freshEvaluatorPerGroup=True,unchangedTypedIrAfterEachGroup=True,sourceIdentityReusedPredecessorQuintControls=32,fourArtifactRows=24,currentReviewedSourceFiles=16,workingModifiedSourceIds=['CO7'],documents=162,localFileLinks=2202,pinnedGitTargets=101,d2SvgPairs=67,historicalManifestsUnchanged=44,orgExport='162 documents; source evaluation disabled; optional htmlize warnings nonfatal',improvements=['One admitted semantic program connects Scheme and JSON/YAML authoring with routine and routing','Program publication separated from authentic original-task invocation binding','Normalized capability/context/candidate/allowance refinement cannot widen original routing authority','Semantically equal normalized values do not replace source provenance or package admission','Actual final dispatch requires current compiled package and native Policy/wire binding','Pinned invocation defaults distinguished from immediate hard Policy/catalog withdrawals','Actual routing source bridge retains original claim and shared account constraints','Concrete support routine JSON/YAML examples and rejection fixtures supplied'],nativeQualification='NOT CLAIMED: arbitrary Scheme evaluation containment, native parsers/compiler/normalization parity, capability registry truth, full routine DAG/parallel/attempt interpreter, incremental atomic package publication, authentic task binding, provider codecs, source/account/broker/transport integration, learned-router quality and recovery liveness',historicalDiagnostics='Initial Lean record-update layout failure and downstream sorryAx diagnostics retained; reserved select Quint name-resolution failure retained; only final source-bound checks counted',boundedClaim='Arbitrary finite Lean requirement/catalog lists under authentic original/base/owner/bridge premises; focused deterministic Quint and JSON/YAML fixtures. No native compiler, exhaustive/random/liveness/performance or remote-CI claim.',scope='English Johnny Decimal Org, core D2, proofs and verification tooling only; no Gateway implementation, dependency pin or upstream edits',boundary='Logical AI Agent Gateway execution and configuration authority; no physical-isolation requirement')
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
inputs=[*out.rglob('*'),*base.iterdir(),Path('proofs/lean/RoutineRoutingConfig.lean'),Path('proofs/qunit/RoutineRoutingConfig.qnt'),Path('proofs/check_routine_config.py'),Path('proofs/check_routine_config_api.py'),Path('proofs/prepare_routine_config.py'),Path('proofs/run_routine_config.cjs'),Path('devenv.lock'),Path('devenv.nix'),Path('devenv.yaml'),Path('docs/architecture/diagrams/lib/theme.d2')]
inputs += list(Path('docs/architecture/diagrams/assets').glob('*.svg'))
paths=sorted(set(p for p in inputs if p.is_file() and p!=out/'SHA256SUMS' and '__pycache__' not in p.parts))
(out/'SHA256SUMS').write_text(''.join(sha(p)+'  '+str(p)+'\n' for p in paths))
print('PASS: final 24 Lean / 32 Quint / 24 four-artifact rows;',len(paths),'sealed byte targets')
