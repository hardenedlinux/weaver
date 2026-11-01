import {test,expect} from 'bun:test';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {closeCompiler} from '../src/compiler-lifecycle';
import {CompilationOwner} from '../src/compiler';
import {collectCatalog} from '../src/source/catalog';
import {fileURLToPath} from 'node:url';

test('already exited child retains failure without writing to a closed IPC channel',async()=>{
 const child=spawn(process.execPath,['-e','throw new Error("compiler failure fixture")'],{stdio:['ignore','ignore','ignore','ipc']});
 await once(child,'exit');
 await expect(closeCompiler(child)).rejects.toThrow('Compiler process exit: 1/');
});
test('disconnected compiler naturally exits and repeated owner close shares one result',async()=>{
 const child=spawn(process.execPath,['-e','process.disconnect()'],{stdio:['ignore','ignore','ignore','ipc']});
 await once(child,'disconnect');
 await closeCompiler(child);
 const owner=new CompilationOwner(collectCatalog(fileURLToPath(new URL('../../../',import.meta.url))));
 const first=owner.close();expect(owner.close()).toBe(first);await first;
 await expect(owner.compile(0)).rejects.toThrow('closing');
});
