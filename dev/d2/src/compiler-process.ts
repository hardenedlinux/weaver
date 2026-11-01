import { Worker } from 'node:worker_threads';
import type { SourceCatalog } from './source/types';
let worker: Worker | undefined;
const sampler = setInterval(() => process.send?.({ memory: true, rssBytes: process.memoryUsage().rss }), 250);
process.on('message', async (message: { catalog: SourceCatalog } | { index: number } | { close: true }) => {
  if ('catalog' in message) {
    worker = new Worker(new URL('./compiler-worker.ts', import.meta.url), { workerData: message.catalog });
    worker.on('message', response => process.send?.({ ...response, rssBytes: process.memoryUsage().rss }));
    worker.on('error', error => process.send?.({ error: error instanceof Error ? error.message : String(error) }));
  } else if ('close' in message) {
    clearInterval(sampler);
    if (worker) await worker.terminate();
    process.disconnect?.();
  } else worker?.postMessage(message.index);
});

process.on('disconnect', async () => { clearInterval(sampler); if (worker) await worker.terminate(); });
