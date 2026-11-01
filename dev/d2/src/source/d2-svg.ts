import path from 'node:path';
import type {Scene} from './types';
const escape=(s:string)=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&#34;').replaceAll("'",'&#39;');
const attribute=(s:string)=>s.replace(/&(amp|lt|gt|quot|apos|#x[0-9a-fA-F]+|#[0-9]+);/g,(_all:string,key:string)=>key.startsWith('#')?String.fromCodePoint(Number.parseInt(key.slice(key.startsWith('#x')?2:1),key.startsWith('#x')?16:10)):({amp:'&',lt:'<',gt:'>',quot:'"',apos:"'"}[key]!));
/** Bind only measured scene groups returned by the shared Library's SVG export. */
export function bindSceneSVG(scene:Pick<Scene,'view'|'nodes'|'edges'>,input:string):string{
 const seen=new Set<string>();
 let svg=input.replace(/<g\b([^>]*?)\bdata-scene-(node|edge)="([^"]+)"([^>]*)>/g,(tag:string,before:string,kind:string,encoded:string,after:string)=>{
  const decoded=attribute(encoded);
  const node=scene.nodes.find(node=>node.id===decoded);
  const edge=scene.edges.find(edge=>edge.id===decoded);
  const id=kind==='node'?node?.id:edge?.id;
  if(!id||seen.has(id))throw new Error('Unknown or repeated measured scene identity: '+encoded);
  seen.add(id);
  return `<g ${before}data-scene-${kind}="${encoded}"${after} ${kind==='node'?`data-source-node="${escape(id)}"`:`data-source-edge="${escape(id)}" data-source-from="${escape(edge!.source)}" data-source-to="${escape(edge!.target)}"`}>`;
 });
 for(const id of [...scene.nodes.map(node=>node.id),...scene.edges.map(edge=>edge.id)])if(!seen.has(id))throw new Error('Measured scene omitted identity: '+id);
 const metadata=escape(JSON.stringify({source:scene.view.source,sourceDigest:scene.view.sha256,nodes:scene.nodes,edges:scene.edges}));
 svg=svg.replace(/<metadata\b[^>]*>[\s\S]*?<\/metadata>/g,'');
 return svg.replace(/(<svg\b[^>]*>)/,`$1<metadata>${metadata}</metadata>`);
}
/** Bind actual native D2 groups, never fabricate empty identity markers. */
export function bindD2SVG(scene:Pick<Scene,'view'|'nodes'|'edges'|'svg'>,files:Record<string,string>):string{
 const nodes=new Map(scene.nodes.map(n=>[Buffer.from(escape(n.id)).toString('base64'),n.id]));
 const edges=new Map(scene.edges.map(e=>[Buffer.from(escape(e.id)).toString('base64'),e]));
 if(nodes.size!==scene.nodes.length||edges.size!==scene.edges.length)throw new Error('Duplicate captured identities');
 const seen=new Set<string>();
 let svg=scene.svg.replace(/<g class="([^"]+)"([^>]*)>/g,(tag:string,classes:string,tail:string)=>{
  for(const key of classes.split(' ')){
   const id=nodes.get(key),edge=edges.get(key);if(!id&&!edge)continue;
   const identity=id??edge!.id;if(seen.has(identity))throw new Error('Duplicate native group: '+identity);seen.add(identity);
   return `<g class="${classes}"${tail} ${id?`data-source-node="${escape(id)}"`:`data-source-edge="${escape(edge!.id)}" data-source-from="${escape(edge!.source)}" data-source-to="${escape(edge!.target)}"`}>`;
  }return tag;
 });
 for(const id of [...scene.nodes.map(n=>n.id),...scene.edges.map(e=>e.id)])if(!seen.has(id))throw new Error('Native library output omitted source group: '+id);
 svg=svg.replace(/(<image\b[^>]*?\b(?:xlink:)?href=")([^"]+)(")/g,(_all:string,start:string,url:string,end:string)=>{
  if(url.startsWith('data:')||url.startsWith('#'))return start+url+end;
  const file=path.posix.normalize(path.posix.join(path.posix.dirname(scene.view.source),url));
  const asset=files[file];if(!asset)throw new Error('Uncaptured native image asset: '+url);
  return start+'data:image/svg+xml;base64,'+Buffer.from(asset).toString('base64')+end;
 });
 const metadata=escape(JSON.stringify({source:scene.view.source,sourceDigest:scene.view.sha256,nodes:scene.nodes,edges:scene.edges}));
 return svg.replace(/(<svg\b[^>]*>)/,`$1<metadata>${metadata}</metadata>`);
}
