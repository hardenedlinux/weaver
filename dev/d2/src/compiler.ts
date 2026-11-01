import { fork, type ChildProcess } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import type { Scene, SourceCatalog } from './source/types';

/** One bounded WASM compiler scope, shared by CPU-parallel image workers. */
export class CompilationOwner {
  private worker?: ChildProcess;
  private jobs = 0;
  rssBytes = 0;
  private queue: Promise<void> = Promise.resolve();
  constructor(private readonly catalog: SourceCatalog) {}
  compile(index: number): Promise<Scene> {
    const result = this.queue.then(async () => {
      if (!this.worker || this.jobs >= 4) {
        if (this.worker) await this.release(this.worker);
        this.worker = fork(fileURLToPath(new URL('./compiler-process.ts', import.meta.url)), [], { execPath: process.execPath, stdio: ['ignore', 'inherit', 'inherit', 'ipc'] });
        this.rssBytes = 0;
        this.worker.on('message', (response: { rssBytes?: number }) => { if (response.rssBytes !== undefined) this.rssBytes = response.rssBytes; });
        this.worker.send({ catalog: this.catalog });
        this.jobs = 0;
      }
      const worker = this.worker;
      this.jobs++;
      return new Promise<Scene>((resolve, reject) => {
        const cleanup = () => { worker.off('message', message); worker.off('error', failed); worker.off('exit', exited); };
        const exited = (code: number | null, signal: string | null) => { cleanup(); reject(new Error('Compiler exited before response: ' + code + '/' + signal)); };
        const failed = (error: Error) => { cleanup(); reject(error); };
        const message = (response: ({ scene: Scene } | { error: string } | { memory: true }) & { rssBytes?: number }) => {
          if ('memory' in response) return;
          this.rssBytes = response.rssBytes ?? 0;
          cleanup();
          if ('error' in response) reject(new Error(response.error));
          else resolve(response.scene);
        };
        worker.on('message', message);
        worker.once('exit', exited);
        worker.once('error', failed);
        worker.send({ index });
      });
    });
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }
  private async release(worker: ChildProcess): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      worker.once('error', reject);
      worker.once('exit', (code, signal) => code === 0 ? resolve() : reject(new Error('Compiler process exit: ' + code + '/' + signal)));
      worker.send({ close: true });
    });
  }
  async close(): Promise<void> {
    await this.queue;
    if (this.worker) await this.release(this.worker);
    this.worker = undefined;
    this.rssBytes = 0;
  }
}
