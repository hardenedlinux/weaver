#!/usr/bin/env python3
"""Verify authoritative canonical registration, cross-protocol alias recovery and original obligations; no Gateway implementation changes."""
from pathlib import Path
import json,os,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'proofs/evidence/llm-result-projection'
MODULES=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection']
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    records=[]
    compiled=Path(tempfile.mkdtemp(prefix='weaver-llm-result-projection-'))
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
        source=('proofs/lean/' if module in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope','LlmRegistryPublication','LlmRecoveryCAS','LlmPolicyPublication','LlmPolicyContinuation','LlmCanonicalRegistry','LlmMultiKeyRegistry','LlmResultProjection'] else 'specs/lean/')+module+'.lean'
        run(module,['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/(module+'.olean')),source],command_env=env)
    log=(OUT/'LlmResultProjection.log').read_text()
    assert 'sorryAx' not in log and 'error:' not in log
    assert sum(line.startswith("'Weaver.LlmResultProjection.") for line in log.splitlines())==22
    source='proofs/qunit/LlmResultProjection.qnt'
    run('typecheck',['quint','typecheck',source])
    run('tests',['quint','test',source,'--backend','typescript','--max-samples','1','--match','Test$'],55)
    (OUT/'itf').mkdir(exist_ok=True)
    run('counterexamples',['quint','test',source,'--backend','typescript','--max-samples','1','--match','CounterexampleTest$',
        '--out-itf','proofs/evidence/llm-result-projection/itf/{test}-{seq}.itf.json'],55)
    for initializer in ['init','committed','sourceOnly','complete','pair','restarted','sent']:
        run(initializer,['quint','run',source,'--backend','typescript','--init',initializer,'--step','step','--invariant','safety',
            '--max-samples','10','--max-steps','30','--seed','199','--verbosity','1'],30)
    run('registry-regression',['quint','test','proofs/qunit/LlmMultiKeyRegistry.qnt','--backend','typescript','--max-samples','1','--match','Test$'],55)
if __name__=='__main__': main()
