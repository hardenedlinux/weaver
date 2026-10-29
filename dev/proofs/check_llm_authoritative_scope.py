#!/usr/bin/env python3
"""Verify original task authority, canonical scope, history and budget composition; no Gateway implementation changes."""
from pathlib import Path
import json,os,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'dev/proofs/evidence/llm-authoritative-scope'
MODULES=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope']
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    records=[]
    compiled=Path(tempfile.mkdtemp(prefix='weaver-llm-authoritative-scope-'))
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
        source=('dev/proofs/lean/' if module in ['GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting','LlmAttemptLedger','LlmSemanticContract','LlmAuthoritativeScope'] else 'dev/specs/lean/')+module+'.lean'
        run(module,['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/(module+'.olean')),source],command_env=env)
    log=(OUT/'LlmAuthoritativeScope.log').read_text()
    assert 'sorryAx' not in log and 'error:' not in log
    assert sum(line.startswith("'Weaver.LlmAuthoritativeScope.") for line in log.splitlines())==21
    source='dev/proofs/quint/LlmAuthoritativeScope.qnt'
    run('typecheck',['quint','typecheck',source])
    run('tests',['quint','test',source,'--backend','typescript','--max-samples','1','--match','Test$'],55)
    (OUT/'itf').mkdir(exist_ok=True)
    run('counterexamples',['quint','test',source,'--backend','typescript','--max-samples','1','--match',
        '(forgedDomain|responseDowngrade|foreignClaim|staleAuthority|historyAlias|toolExpansion|newScopeReplay|unknownRefund)ScopeCounterexampleTest$',
        '--out-itf','dev/proofs/evidence/llm-authoritative-scope/itf/{test}-{seq}.itf.json'],55)
    for initializer in ['init','initMissing','registered','prepared','invoked','winner','recovered']:
        run(initializer,['quint','run',source,'--backend','typescript','--init',initializer,'--step','step','--invariant','safety',
            '--max-samples','10','--max-steps','30','--seed','163','--verbosity','1'],30)
    run('semantic-regression',['quint','test','dev/proofs/quint/LlmSemanticContract.qnt','--backend','typescript','--max-samples','1','--match','Test$'],55)
if __name__=='__main__': main()
