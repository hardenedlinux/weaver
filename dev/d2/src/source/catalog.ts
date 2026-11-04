// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { isViewKind, type SourceCatalog, type ViewEntry } from './types';
import {readModelCapture,capturedViews} from './models';

function files(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if (entry.isSymbolicLink()) throw new Error(`Design source alias: ${entry.name}`);
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? (entry.name === 'lib' ? [] : files(file)) : [file];
  });
}
export function collectCatalog(root: string, selection?: readonly string[]): SourceCatalog {
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
  const modelFiles=files(path.join(root,'dev/sysml')).filter(file=>file.endsWith('.sysml')).map(file=>path.relative(root,file).split(path.sep).join('/'));
  const documents=Object.fromEntries(["Project.sysml","docs/architecture/08-diagram-catalog.org",...modelFiles].map(name=>[name,readFileSync(path.join(root,name),"utf8")]));
  const expected=process.env.WEAVER_DIAGRAM_MODEL_SHA256;
  const rawCapture=expected?readFileSync(path.join(root,'.cache/d2/model-views.json'),'utf8'):undefined;
  if(rawCapture){
    const metadata:unknown=JSON.parse(rawCapture);
    if(metadata&&typeof metadata==='object'&&'proofSources' in metadata&&metadata.proofSources&&typeof metadata.proofSources==='object'){
      for(const name of Object.keys(metadata.proofSources)){
        if(!name.startsWith('dev/proofs/')||!name.endsWith('.lean')||name.split('/').includes('..'))throw new Error('Nonlocal captured Lean source');
        documents[name]=readFileSync(path.join(root,name),'utf8');
      }
    }
  }
  const modelCapture=expected?readModelCapture(rawCapture!,expected,{...fs,...documents},selection):undefined;
  for(const[view,capture]of Object.entries(capturedViews(modelCapture)))documents['dev/sysml/captures/'+view.replaceAll('::','-')+'.json']=JSON.stringify(capture);
  for (const name of ['go', 'rust', 'kubernetes']) {
    const source = `docs/architecture/diagrams/assets/${name}.svg`;
    fs[source] = readFileSync(path.join(root, source), 'utf8');

  }
  views.sort((a, b) => a.source.localeCompare(b.source));
  return { views, fs, documents,modelCapture };
}
