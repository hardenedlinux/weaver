import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { isViewKind, type SourceCatalog, type ViewEntry } from './types';

function files(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if (entry.isSymbolicLink()) throw new Error(`Design source alias: ${entry.name}`);
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? (entry.name === 'lib' ? [] : files(file)) : [file];
  });
}
export function collectCatalog(root: string): SourceCatalog {
  const fs: Record<string, string> = {};
  const views: ViewEntry[] = [];
  for (const file of [...files(path.join(root, 'docs')).filter(file => file.endsWith('.d2')), ...files(path.join(root, 'dev/d2/themes')).filter(file => file.endsWith('.d2'))]) {
    const source = path.relative(root, file).split(path.sep).join('/');
    const text = readFileSync(file, 'utf8');
    fs[source] = text;
    if (!source.startsWith('docs/')) continue;
    const profile = text.match(/^\.\.\.@[^\n]*\/themes\/(\w+)\s*$/m)?.[1];
    if (!profile || !isViewKind(profile)) throw new Error(`Missing view profile: ${source}`);
    const title = text.match(/^title:\s*([^\n{]+)/m)?.[1]?.trim() ?? path.basename(file, '.d2').replace(/^\d+[.-]/, '').replaceAll('-', ' ');
    views.push({ id: source, source, title, kind: profile, sha256: createHash('sha256').update(text).digest('hex') });
  }
  for (const file of files(path.join(root, "dev/d2/node_modules/@deterministic-engineering/render/themes"))) {
    if (file.endsWith(".d2")) fs[path.relative(root,file).split(path.sep).join("/")] = readFileSync(file,"utf8");
  }
  const documents=Object.fromEntries(["Project.sysml","docs/architecture/08-diagram-catalog.org"].map(name=>[name,readFileSync(path.join(root,name),"utf8")]));
  for (const name of ['go', 'rust', 'kubernetes']) {
    const source = `docs/architecture/diagrams/assets/${name}.svg`;
    fs[source] = readFileSync(path.join(root, source), 'utf8');

  }
  views.sort((a, b) => a.source.localeCompare(b.source));
  return { views, fs, documents };
}
