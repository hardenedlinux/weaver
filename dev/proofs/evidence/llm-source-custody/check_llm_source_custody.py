#!/usr/bin/env python3
"""Verify recoverable source custody and actual determining admission floor CAS."""
from pathlib import Path
import json,os,subprocess,tempfile,time,hashlib,sys,re
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'proofs/evidence/llm-source-custody'
MODULES=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff','LlmAdmissionFloor','LlmSourceJoin','LlmSourceCustody']
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    records=[]
    compiled=Path(tempfile.mkdtemp(prefix='weaver-llm-source-custody-'))
    if '--resume-lean' in sys.argv:
        previous=json.loads((OUT/'commands.json').read_text())
        records=[r for r in previous if r['label'] in MODULES]
        assert [r['label'] for r in records]==MODULES and all(r['exit']==0 for r in records)
        for r in records:
            assert 'error:' not in (OUT/(r['label']+'.log')).read_text()
            assert all(hashlib.sha256((ROOT/a).read_bytes()).hexdigest()==digest for a,digest in r['sourceSha256'].items())
            assert Path(r['args'][-2]).is_file()
        compiled=Path(records[-1]['args'][-2]).parent
    env=dict(os.environ,LEAN_PATH=str(compiled))
    def run(label,args,watchdog=20,command_env=None):
        started=time.monotonic()
        inputs={a:hashlib.sha256((ROOT/a).read_bytes()).hexdigest() for a in args if a.endswith(('.lean','.qnt')) and (ROOT/a).is_file()}
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
        source=('proofs/lean/' if module in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff','LlmAdmissionFloor','LlmSourceJoin','LlmSourceCustody'] else 'specs/lean/')+module+'.lean'
        run(module,['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/(module+'.olean')),source],command_env=env)
    log=(OUT/'LlmSourceCustody.log').read_text()
    assert 'sorryAx' not in log and 'error:' not in log
    assert sum(line.startswith("'Weaver.LlmSourceCustody.") for line in log.splitlines())==13
    source='proofs/qunit/LlmSourceCustody.qnt'
    run('typecheck',['quint','typecheck',source])
    own_tests=re.findall(r'^  run (\w+Test)=', (ROOT/source).read_text(), re.M)
    assert len(own_tests)==23
    run('tests',['quint','test',source,'--backend','typescript','--max-samples','1','--match','^('+'|'.join(own_tests)+')$'],55)
    (OUT/'itf').mkdir(exist_ok=True)
    run('counterexamples',['quint','test',source,'--backend','typescript','--max-samples','1','--match','CustodyCounterexampleTest$',
        '--out-itf','proofs/evidence/llm-source-custody/itf/{test}-{seq}.itf.json'],55)
    for initializer in ['init','armed','handed','recovered','committed','transferredCommit','resolvedCommit','restarted','closed']:
        run(initializer,['quint','run',source,'--backend','typescript','--init',initializer,'--step','step','--invariant','safety',
            '--max-samples','10','--max-steps','30','--seed','269','--verbosity','1'],30)
    run('join-regression',['quint','test','proofs/qunit/LlmSourceJoin.qnt','--backend','typescript','--max-samples','1','--match','Test$'],55)
if __name__=='__main__': main()
