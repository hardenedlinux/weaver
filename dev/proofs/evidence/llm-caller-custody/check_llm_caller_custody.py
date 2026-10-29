#!/usr/bin/env python3
"""Verify protected custody/floor publication and recovery."""
from pathlib import Path
import json,os,subprocess,tempfile,time,hashlib,sys,re
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'proofs/evidence/llm-caller-custody'
MODULES=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff','LlmAdmissionFloor','LlmSourceJoin','LlmSourceCustody','LlmCustodyPublication','LlmCallerCustody']
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    records=[]
    prior_timeout=None
    if '--reuse-typecheck-timeout' in sys.argv:
        previous=json.loads((OUT/'commands.json').read_text())
        prior_timeout=next(r for r in previous if r['label']=='typecheck')
        assert prior_timeout['exit']==124
        for path,digest in prior_timeout['sourceSha256'].items():
            assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==digest
    compiled=Path(tempfile.mkdtemp(prefix='weaver-llm-caller-custody-'))
    if '--resume-lean' in sys.argv or '--resume-models' in sys.argv:
        retained=MODULES if '--resume-models' in sys.argv else MODULES[:-1]
        previous=json.loads((OUT/'commands.json').read_text())
        records=[r for r in previous if r['label'] in retained]
        assert [r['label'] for r in records]==retained and all(r['exit']==0 for r in records)
        for r in records:
            assert 'error:' not in (OUT/(r['label']+'.log')).read_text()
            assert all(hashlib.sha256((ROOT/a).read_bytes()).hexdigest()==digest for a,digest in r['sourceSha256'].items())
            assert Path(r['args'][-2]).is_file()
        compiled=Path(records[-1]['args'][-2]).parent
    env=dict(os.environ,LEAN_PATH=str(compiled))
    def run(label,args,watchdog=20,command_env=None):
        started=time.monotonic()
        inputs={a:hashlib.sha256((ROOT/a).read_bytes()).hexdigest() for a in args if a.endswith(('.lean','.qnt','.py')) and (ROOT/a).is_file()}
        with (OUT/(label+'.log')).open('w') as log:
            try: code=subprocess.run(args,cwd=ROOT,env=command_env,stdout=log,stderr=subprocess.STDOUT,timeout=watchdog).returncode
            except subprocess.TimeoutExpired: code=124
        assert all(hashlib.sha256((ROOT/a).read_bytes()).hexdigest()==digest for a,digest in inputs.items()),'Source changed during verification'
        records.append(dict(label=label,args=args,sourceSha256=inputs,exit=code,seconds=round(time.monotonic()-started,3),watchdogSeconds=watchdog))
        (OUT/'commands.json').write_text(json.dumps(records,indent=2)+'\n')
        print(label,code,flush=True)
        if code: raise SystemExit(code)
    completed={r['label'] for r in records}
    for module in MODULES:
        if module in completed: continue
        source=('proofs/lean/' if module in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff','LlmAdmissionFloor','LlmSourceJoin','LlmSourceCustody','LlmCustodyPublication','LlmCallerCustody'] else 'specs/lean/')+module+'.lean'
        run(module,['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/(module+'.olean')),source],command_env=env)
    log=(OUT/'LlmCallerCustody.log').read_text()
    assert 'sorryAx' not in log and 'error:' not in log
    assert sum(line.startswith("'Weaver.LlmCallerCustody.") for line in log.splitlines())==22
    run('prepare-closure',[sys.executable,'proofs/prepare_llm_caller_closure.py'])
    source='proofs/evidence/llm-caller-custody/quint-core/LlmCallerCustody.qnt'
    if prior_timeout is None:
        run('typecheck',['quint','typecheck',source])
    else:
        assert prior_timeout['args']==['quint','typecheck',source]
        records.append(prior_timeout)
        (OUT/'commands.json').write_text(json.dumps(records,indent=2)+'\n')
        print('typecheck: retained prior fixed-watchdog timeout; test pipeline must independently typecheck',flush=True)
    own_tests=re.findall(r'^  run (\w+Test)=', (ROOT/source).read_text(), re.M)
    assert len(own_tests)==27
    run('tests',['quint','test',source,'--backend','typescript','--max-samples','1','--match','^('+'|'.join(own_tests)+')$'],55)
    (OUT/'itf').mkdir(exist_ok=True)
    run('counterexamples',['quint','test',source,'--backend','typescript','--max-samples','1','--match','CallerCounterexampleTest$',
        '--out-itf','proofs/evidence/llm-caller-custody/itf/{test}-{seq}.itf.json'],55)
    for initializer in ['boot','staged','committed','handed','recovered','rotated','restarted','expired']:
        run(initializer,['quint','run',source,'--backend','typescript','--init',initializer,'--step','step','--invariant','invariant',
            '--max-samples','10','--max-steps','30','--seed','283','--verbosity','1'],30)
    parent='proofs/evidence/llm-custody-publication/quint-core/LlmCustodyPublication.qnt'
    parent_tests=re.findall(r'^  run (\w+Test)=', (ROOT/parent).read_text(), re.M)
    assert len(parent_tests)==25
    run('publication-regression',['quint','test',parent,'--backend','typescript','--max-samples','1','--match','^('+'|'.join(parent_tests)+')$'],55)
if __name__=='__main__': main()
