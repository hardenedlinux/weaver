import { parentPort, workerData } from 'node:worker_threads';
import { SourceCompiler } from './source/compile';
import type { SourceCatalog, Scene } from './source/types';
const catalog = workerData as SourceCatalog;
const compiler = new SourceCompiler(catalog);
if (!parentPort) throw new Error('Compiler requires an owned worker port');
parentPort.on('message', async (index: number) => {
  try {
    const view = catalog.views[index];
    if (!view) throw new Error('Unknown source index');
    parentPort?.postMessage({ scene: await compiler.compile(view) } satisfies { scene: Scene });
  } catch (error: unknown) {
    parentPort?.postMessage({ error: error instanceof Error ? error.message : String(error) });
  }
});
