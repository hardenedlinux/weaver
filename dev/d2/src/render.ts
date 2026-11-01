import { CompilationOwner } from './compiler';
import { Worker } from 'node:worker_threads';
import { cpus } from 'node:os';
import { fileURLToPath } from 'node:url';
import { mkdir, writeFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import path from 'node:path';
import { collectCatalog } from './source/catalog';
import type { RenderResponse, ViewImage } from './worker';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const catalog = collectCatalog(root);
const { values } = parseArgs({ args: process.argv.slice(2), options: { view: { type: 'string', multiple: true } } });
const requested = values.view;
const indexes = catalog.views.flatMap((view, index) => !requested || requested.includes(view.source) ? [index] : []);
if (requested && indexes.length !== new Set(requested).size) throw new Error('A requested D2 view does not exist');
if (!indexes.length) throw new Error('No D2 views selected');
let cursor = 0;
const images: ViewImage[] = [];
const errors: string[] = [];
const count = Math.min(cpus().length, indexes.length);
const workers: Worker[] = [];
const compiler = new CompilationOwner(catalog);
let peakRSSBytes = process.memoryUsage().rss;
let cancelled = false;
const memoryBudgetBytes = 4 * 1024 ** 3;
const memorySampler = setInterval(() => {
  peakRSSBytes = Math.max(peakRSSBytes, process.memoryUsage().rss + compiler.rssBytes);
  if (peakRSSBytes > memoryBudgetBytes && !cancelled) {
    errors.push('Renderer exceeded 4 GiB RSS admission budget; stop scheduling and drain owned jobs');
    cancelled = true;
  }
}, 250);
const stop = () => { cancelled = true; };
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
try {
  await Promise.all(Array.from({ length: count }, async () => {
    while (!cancelled && cursor < indexes.length) {
      const worker = new Worker(new URL('./worker.tsx', import.meta.url), { workerData: { root, catalog } });
      workers.push(worker);
      try {
        // Bound each WASM scope's lifetime without reducing host parallelism.
        await new Promise<void>((resolve, reject) => {
          let completed = 0;
          const next = async () => {
            if (cancelled || completed >= 4) { resolve(); return; }
            const index = indexes[cursor++];
            if (index === undefined) resolve();
            else {
              try {
                const scene = await compiler.compile(index);
                if (cancelled) resolve(); else worker.postMessage({ index, scene });
              } catch (error: unknown) { reject(error); }
            }
          };
          worker.on('error', reject);
          worker.on('message', (message: RenderResponse) => {
            if ('error' in message) { errors.push(`${catalog.views[message.index]?.source}: ${message.error}`); console.error(errors[errors.length - 1]); }
            else { images.push(message.image); console.log(`[${message.image.theme}] ${message.image.source}`); }
            completed++;
            next();
          });
          next();
        });
      } finally {
        await worker.terminate();
        workers.splice(workers.indexOf(worker), 1);
      }
    }
  }));
} finally {
  clearInterval(memorySampler);
  await compiler.close();
  // The public Worker API releases each owned rendering scope, including SDK workers.
  await Promise.all(workers.map(worker => worker.terminate()));
  process.off('SIGINT', stop);
  process.off('SIGTERM', stop);
}
const current = collectCatalog(root);
if (cancelled) errors.push('Image rendering cancelled after owned jobs drained');
if (JSON.stringify(current) !== JSON.stringify(catalog)) errors.push('D2 sources, themes or brand assets changed during rendering');
if (images.length !== indexes.length) errors.push('Not every requested view produced an image');
images.sort((a, b) => a.source.localeCompare(b.source));
await mkdir(path.join(root, '.cache/d2'), { recursive: true });
await writeFile(path.join(root, '.cache/d2/typescript-render.json'), JSON.stringify({ status: errors.length ? 'FAIL' : 'PASS', hostCPUs: cpus().length, workers: count, compilerWorkers: 1, memoryBudgetBytes, peakRSSBytes, images, errors }, null, 2));
if (errors.length) throw new Error(`${errors.length} renderer failures; see .cache/d2/typescript-render.json`);
console.log(`PASS: ${images.length} SVG/PNG images, ${count} workers, no HTTP service`);
