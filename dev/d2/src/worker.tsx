import { parentPort, workerData } from 'node:worker_threads';
import { mkdir, writeFile, access } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { renderToStaticMarkup } from 'react-dom/server';
import { Resvg } from '@resvg/resvg-js';
import { layoutScene } from './graph/layout';
import { ArchitectureImage } from './scene/Scene';
import type { SourceCatalog, Scene } from './source/types';

export interface RenderJob { index: number; scene: Scene; }
export interface ViewImage {
  source: string; theme: string; sourceSHA256: string; svgSHA256: string; pngSHA256: string;
  width: number; height: number; nodes: number; edges: number;
}
export type RenderResponse = { index: number; image: ViewImage } | { index: number; error: string };
const { root, catalog } = workerData as { root: string; catalog: SourceCatalog };
const hash = (data: string | Uint8Array) => createHash('sha256').update(data).digest('hex');
if (!parentPort) throw new Error('Renderer needs an owned worker port');
parentPort.on('message', async (job: RenderJob) => {
  try {
    const view = catalog.views[job.index];
    if (!view) throw new Error(`Unknown view index: ${job.index}`);
    const scene = await layoutScene(job.scene);
    const svg = `<?xml version="1.0" encoding="UTF-8"?>\n${renderToStaticMarkup(<ArchitectureImage scene={scene} brands={catalog.brands}/>)}`;
    const png = new Resvg(svg, { fitTo: { mode: 'width', value: 1800 } }).render().asPng();
    const stem = path.join(root, view.source.slice(0, -3));
    const preview = path.join(root, '.cache/d2/images', `${view.source.slice(0, -3)}.png`);
    await mkdir(path.dirname(preview), { recursive: true });
    await writeFile(`${stem}.svg`, svg);
    await writeFile(preview, png);
    const existingPNG = await access(`${stem}.png`).then(() => true, () => false);
    if (existingPNG) await writeFile(`${stem}.png`, png);
    const image: ViewImage = { source: view.source, theme: view.kind, sourceSHA256: view.sha256, svgSHA256: hash(svg), pngSHA256: hash(png), width: scene.width, height: scene.height, nodes: scene.nodes.length, edges: scene.edges.length };
    parentPort?.postMessage({ index: job.index, image } satisfies RenderResponse);
  } catch (error: unknown) {
    parentPort?.postMessage({ index: job.index, error: error instanceof Error ? error.stack ?? error.message : String(error) } satisfies RenderResponse);
  }
});
