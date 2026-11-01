import type {ChildProcess} from 'node:child_process';

/** Drain an owned compiler. A disconnected/exited child cannot receive a close command. */
export function closeCompiler(worker:ChildProcess):Promise<void>{
 const result=()=>worker.exitCode===0?undefined:new Error(`Compiler process exit: ${worker.exitCode}/${worker.signalCode}`);
 if(worker.exitCode!==null||worker.signalCode!==null){const error=result();return error?Promise.reject(error):Promise.resolve();}
 return new Promise((resolve,reject)=>{
  const cleanup=()=>{worker.off('error',failed);worker.off('exit',exited);};
  const failed=(error:Error)=>{cleanup();reject(error);};
  const exited=()=>{cleanup();const error=result();if(error)reject(error);else resolve();};
  worker.once('error',failed);worker.once('exit',exited);
  if(worker.connected)worker.send({close:true},error=>{if(error&&worker.connected)failed(error);});
 });
}
