import { Worker } from 'node:worker_threads';
import type { Scene, SourceCatalog } from './source/types';

/** One bounded WASM compiler scope, shared by CPU-parallel image workers. */
export class CompilationOwner {
  private worker?: Worker;
  private jobs = 0;
  private queue: Promise<void> = Promise.resolve();
  constructor(private readonly catalog: SourceCatalog) {}
  compile(index: number): Promise<Scene> {
    const result = this.queue.then(async () => {
      if (!this.worker || this.jobs >= 4) {
        if (this.worker) await this.worker.terminate();
        this.worker = new Worker(new URL('./compiler-worker.ts', import.meta.url), { workerData: this.catalog });
        this.jobs = 0;
      }
      const worker = this.worker;
      this.jobs++;
      return new Promise<Scene>((resolve, reject) => {
        const cleanup = () => { worker.off('message', message); worker.off('error', failed); };
        const failed = (error: Error) => { cleanup(); reject(error); };
        const message = (response: { scene: Scene } | { error: string }) => {
          cleanup();
          if ('error' in response) reject(new Error(response.error));
          else resolve(response.scene);
        };
        worker.once('message', message);
        worker.once('error', failed);
        worker.postMessage(index);
      });
    });
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }
  async close(): Promise<void> {
    await this.queue;
    if (this.worker) await this.worker.terminate();
    this.worker = undefined;
  }
}
