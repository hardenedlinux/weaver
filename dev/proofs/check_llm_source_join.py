#!/usr/bin/env python3
"""Verify admission floor and source-owner join at actual publication CAS."""
from pathlib import Path
import json,os,subprocess,tempfile,time,hashlib
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'dev/proofs/evidence/llm-source-join'
MODULES=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff','LlmAdmissionFloor','LlmSourceJoin']
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    records=[]
    compiled=Path(tempfile.mkdtemp(prefix='weaver-llm-source-join-'))
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
    for module in MODULES:
        source=('dev/proofs/lean/' if module in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection','LlmJoinEnqueue','LlmExecutorOffer','LlmExecutionReconciliation','LlmAccountCommit','LlmWalActivation','LlmCheckpointTruncation','LlmManifestSwitch','LlmAppendHandoff','LlmAdmissionFloor','LlmSourceJoin'] else 'dev/specs/lean/')+module+'.lean'
        run(module,['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/(module+'.olean')),source],command_env=env)
    log=(OUT/'LlmSourceJoin.log').read_text()
    assert 'sorryAx' not in log and 'error:' not in log
    assert sum(line.startswith("'Weaver.LlmSourceJoin.") for line in log.splitlines())==14
    source='dev/proofs/quint/LlmSourceJoin.qnt'
    run('typecheck',['quint','typecheck',source])
    run('tests',['quint','test',source,'--backend','typescript','--max-samples','1','--match','Test$'],55)
    (OUT/'itf').mkdir(exist_ok=True)
    run('counterexamples',['quint','test',source,'--backend','typescript','--max-samples','1','--match','JoinCounterexampleTest$',
        '--out-itf','dev/proofs/evidence/llm-source-join/itf/{test}-{seq}.itf.json'],55)
    for initializer in ['init','staged','accountChanged','sourceChanged','sourceReallowed','fenced','appendInit','appendStaged','appendPublished']:
        run(initializer,['quint','run',source,'--backend','typescript','--init',initializer,'--step','step','--invariant','safety',
            '--max-samples','10','--max-steps','30','--seed','263','--verbosity','1'],30)
    run('floor-regression',['quint','test','dev/proofs/quint/LlmAdmissionFloor.qnt','--backend','typescript','--max-samples','1','--match','Test$'],55)
if __name__=='__main__': main()
