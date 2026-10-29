#!/usr/bin/env python3
"""Verify Gateway logical head/CAS semantics without hardware prerequisites or pin changes."""
from pathlib import Path
import json,os,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'proofs/evidence/gateway-head-cas'
MODULES=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS']
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    records=[]
    compiled=Path(tempfile.mkdtemp(prefix='weaver-gateway-head-cas-'))
    env=dict(os.environ,LEAN_PATH=str(compiled))
    def run(label,args,watchdog=20,command_env=None):
        started=time.monotonic()
        with (OUT/(label+'.log')).open('w') as log:
            try: code=subprocess.run(args,cwd=ROOT,env=command_env,stdout=log,stderr=subprocess.STDOUT,timeout=watchdog).returncode
            except subprocess.TimeoutExpired: code=124
        records.append(dict(label=label,args=args,exit=code,seconds=round(time.monotonic()-started,3),watchdogSeconds=watchdog))
        (OUT/'commands.json').write_text(json.dumps(records,indent=2)+'\n')
        print(label,code,flush=True)
        if code: raise SystemExit(code)
    for module in MODULES:
        source=('proofs/lean/' if module=='GatewayHeadCAS' else 'specs/lean/')+module+'.lean'
        run(module,['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/(module+'.olean')),source],command_env=env)
    log=(OUT/'GatewayHeadCAS.log').read_text()
    assert 'sorryAx' not in log and 'error:' not in log
    assert sum(line.startswith("'Weaver.GatewayHeadCAS.") for line in log.splitlines())==23
    source='proofs/qunit/GatewayHeadCAS.qnt'
    run('typecheck',['quint','typecheck',source])
    run('tests',['quint','test',source,'--backend','typescript','--max-samples','1','--match','Test$'],55)
    (OUT/'itf').mkdir(exist_ok=True)
    run('counterexamples',['quint','test',source,'--backend','typescript','--max-samples','1','--match',
        '(semanticPublicationCAS|staleHeadCAS|oldWorkerCAS|duplicateRootCompletion|preparedProjectionAsCommit|staleJoinAfterNewFence|redirectedFinalSend)CounterexampleTest$',
        '--out-itf','proofs/evidence/gateway-head-cas/itf/{test}-{seq}.itf.json'],55)
    for initializer in ['originals','admitted','prepared','committed','materialized','ready']:
        run(initializer,['quint','run',source,'--backend','typescript','--init',initializer,'--step','step','--invariant','safety',
            '--max-samples','10','--max-steps','25','--seed','131','--verbosity','1'],30)
    run('finite-domain-regression',['quint','test','specs/quint/FiniteDomainMigration.qnt','--backend','typescript','--max-samples','1','--match','Test$'],55)
if __name__=='__main__': main()
