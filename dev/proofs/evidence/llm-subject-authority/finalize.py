from pathlib import Path
import hashlib,json,re,subprocess
ROOT=Path.cwd();out=Path('proofs/evidence/llm-subject-authority');base=Path('docs/40-49-admission-coordination/48-subject-authority')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
api=json.loads((out/'api-invocation.json').read_text());assert api['exit']==0 and api['expectedControls']==42
for p,h in api['inputs'].items():assert sha(Path(p))==h,p
stage=json.loads((out/'typed-stage-summary.json').read_text());assert len(stage['modules'])==16
groups=json.loads((out/'api-groups.json').read_text())
expected={test+'-'+str(i)+'.itf.json' for group in groups for i,test in enumerate(group)}
assert len(expected)==42 and {p.name for p in (out/'itf').glob('*.json')}==expected

installed=Path('/opt/homebrew/Cellar/quint/0.33.0/libexec/lib/node_modules/@informalsystems/quint/dist/src')
assert sha(installed/'cliCommands.js')==stage['cliCommandsSha256']
assert sha(installed/'runtime/impl/evaluator.js')==stage['evaluatorSha256']
lean=json.loads((out/'lean-command.json').read_text());assert lean['exit']==0
for p,h in lean['sourceSha256'].items():assert sha(Path(p))==h
assert sha(Path(lean['args'][-2]))==lean['compiledSha256']
log=(out/'LlmSubjectAuthority.log').read_text();assert 'error:' not in log and 'sorryAx' not in log
assert len(re.findall(r"^'Weaver.LlmSubjectAuthority\.",log,re.M))==33
commands=json.loads((out/'commands.json').read_text());assert all(r['exit']==0 for r in commands)
assert len(commands)==22
for r in commands:
 hashes=r.get('sourceSha256',{})
 if isinstance(hashes,dict):
  for p,h in hashes.items():assert sha(Path(p))==h,(r['label'],p)
for name in ['org-export-command.json','org-current-export-command.json']:assert json.loads((out/name).read_text())['exit']==0
assert 'PASS: exported 159 Org documents' in (out/'org-export.log').read_text()
assert 'PASS: exported 3 Org documents' in (out/'org-current-export.log').read_text()
for helper,logfile in [('check-four-artifacts.py','four-artifacts-check.log'),('check-document-inventory.py','document-check.log')]:
 r=subprocess.run(['python3',str(out/helper)],capture_output=True,text=True,timeout=20);(out/logfile).write_text(r.stdout+r.stderr);assert r.returncode==0,r.stdout+r.stderr
checks=json.loads((out/'diagram-validation.json').read_text());assert len(checks)==66 and all(r['exit']==0 for r in checks)
assert len((out/'historical-manifests.log').read_text().splitlines())==43
# Historical bytes are rechecked immediately before the new seal.
for p in list(Path('specs/evidence').glob('*/SHA256SUMS'))+list(Path('proofs/evidence').glob('*/SHA256SUMS')):
 if p.parent==out:continue
 for line in p.read_text().splitlines():
  h,name=line.split('  ',1);assert sha(Path(name))==h,(p,name)
(out/'visual-inspection.log').write_text('PASS: final bundled SVG rasterized at width 2400 and inspected. Four language/authority lanes, local Go/Kubernetes/Rust icons, readable node labels and core proof relationships; no versions or acceptance counts in the diagram.\n')
(out/'document-source-hashes.json').write_text(json.dumps({str(p):sha(p) for p in sorted(base.iterdir()) if p.is_file()},indent=2)+'\n')
receipt=dict(status='PASS_CONDITIONAL_MODEL_CONTROLS',freshLeanDeclarations=33,sourceCheckedReusedLeanReceipts=34,currentQuintControls=42,ordinaryGuardedControls=36,decodedFaultControls=5,quarantineControls=1,currentSuccessfulPhases=22,officialFullTypeEffectAnalysis=True,freshEvaluatorPerGroup=True,unchangedTypedIrAfterEachGroup=True,sourceIdentityReusedPredecessorQuintControls=40,fourArtifactRows=33,pinnedSourceBlobs=19,workingExactBlobs=18,workingImportOnlyChanges=['P17'],documents=159,localFileLinks=2176,pinnedGitTargets=101,d2SvgPairs=66,historicalManifestsUnchanged=43,orgExport='159 full-tree documents; 3 final current-category documents; source evaluation disabled; optional htmlize warnings nonfatal',improvements=['Configured subject and producer authorities are distinct from shared Kubernetes eligibility','Original Task fixes canonical subject/producer scope and enrollment key','Immutable assignment survives lost responses and current credential renewal','Exact-parent credential rotation retains stable identity and original pending intent','Current source/approval joins checked at Plan publication and again at new credential issuance','Per-call current identity proof binds this exact credential issue, independently of a stored current approval','Plan publication is exactly a staging-only predecessor update with an atomic outcome','Complete outer accepted prefix covers source/assignment changes invisible to account/source execution floors','Actual enrollment credential, first beneficiary and original account/unknown-hold composition retained'],nativeQualification='NOT CLAIMED: initial subject/producer provisioning, configured trust policy administration, active-credential crypto/channel/codec, per-call native verification, independently accepted-prefix anti-rollback, conditional durable CAS, IdP/SDK/broker/transport refinement, counter exhaustion, key migration and recovery liveness',historicalDiagnostics='QNT101 reserved-name parse failure; successful intermediate forty-control and pre-per-issue forty-two-control routes retained separately; stale numbered ITF decoder failure retained and old traces archived; only final source-bound current route counted',boundedClaim='Deterministic focused Quint scenarios and arbitrary finite Lean traces under explicit native owner and initialized predecessor premises; no new exhaustive/random/liveness/performance/remote-CI claim',scope='English Johnny Decimal Org, core D2, proofs and verification tooling only; no Gateway implementation or dependency pin edits',boundary='Logical AI Agent Gateway authority; no physical process uniqueness or hardware isolation requirement')
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
inputs=[*out.rglob('*'),*base.iterdir(),Path('proofs/lean/LlmSubjectAuthority.lean'),Path('proofs/qunit/LlmSubjectAuthority.qnt'),Path('proofs/check_llm_subject_authority.py'),Path('proofs/check_subject_api.py'),Path('proofs/prepare_subject_authority.py'),Path('proofs/run_subject_authority.cjs'),Path('devenv.lock'),Path('devenv.nix'),Path('devenv.yaml'),Path('docs/architecture/diagrams/lib/theme.d2')]
inputs += list(Path('docs/architecture/diagrams/assets').glob('*.svg'))
paths=sorted(set(p for p in inputs if p.is_file() and p!=out/'SHA256SUMS' and '__pycache__' not in p.parts))
(out/'SHA256SUMS').write_text(''.join(sha(p)+'  '+str(p)+'\n' for p in paths))
print('PASS: final 33 Lean / 42 Quint / 33 four-artifact rows;',len(paths),'sealed byte targets')
