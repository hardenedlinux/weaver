import {test,expect} from 'bun:test';
import {chromium} from 'playwright';
import {fileURLToPath} from 'node:url';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const root=fileURLToPath(new URL('../../../',import.meta.url));
const hash=(value:string)=>createHash('sha256').update(value).digest('hex');
test('all Library model SVGs retain legible fonts, vector icons and complete text at GitHub width',async()=>{
 const receipt:{status:string;report:{selection?:string[];modelCaptureSHA256:string;images:{source:string;layout:string;sourceSHA256:string;svgSHA256:string}[]}}=JSON.parse(await readFile(root+'.cache/d2/latest-render.json','utf8'));
 const modelDigest=process.env.WEAVER_DIAGRAM_MODEL_SHA256;
 if(!modelDigest)throw new Error('Standalone vector admission requires the Go-owned SDK capture');
 expect(receipt.status).toBe('PASS');
 expect(receipt.report.modelCaptureSHA256).toBe(modelDigest);
 const images=receipt.report.images.filter(image=>image.layout==='model-view'||image.layout==='sequence-view');
 if(receipt.report.selection){expect(images.map(image=>image.source).sort()).toEqual([...receipt.report.selection].sort());expect(images.length).toBeGreaterThan(0);}
 else expect(images.length).toBeGreaterThan(3);
 const browser=await chromium.launch();
 const failures:string[]=[];
 try{
  for(const image of images){
   const name=image.source.split('/').at(-1)!.slice(0,-3);
   const body=await readFile(root+image.source.slice(0,-3)+'.svg','utf8');
   expect(createHash('sha256').update(body).digest('hex')).toBe(image.svgSHA256);
   const page=await browser.newPage({viewport:{width:830,height:1000}});
   try{
    const cache=root+'.cache/d2/images/'+image.source.slice(0,-3);
    const html=await readFile(cache+'.html','utf8');
    const exported:{htmlSHA256:string;inputSHA256:string}=JSON.parse(await readFile(cache+'.json','utf8'));
    expect(hash(html)).toBe(exported.htmlSHA256);
    await page.setContent(html);await page.evaluate(()=>document.fonts.ready);
    const provenance:{inputSHA256:string;sourceSHA256:Record<string,string>}=JSON.parse(await page.locator('#figure-provenance').textContent()??'');
    expect(provenance.inputSHA256).toBe(exported.inputSHA256);
    expect(provenance.sourceSHA256[image.source]).toBe(image.sourceSHA256);
    await page.setContent('<style>body{margin:0;background:#0d1117}body>svg{width:830px;height:auto}</style>'+body);
    await page.evaluate(()=>document.fonts.ready);
    const issues=await page.evaluate(()=>{
     const problems:string[]=[],root=document.querySelector('body>svg')!.getBoundingClientRect();
     const canvas=document.querySelector('body>svg>rect');
     if(!canvas||getComputedStyle(canvas).fill==='rgba(0, 0, 0, 0)'||getComputedStyle(canvas).fill==='none')problems.push('Transparent standalone canvas');
     for(const text of document.querySelectorAll<SVGTextElement>('svg[data-vector-annotation] text,.scene-copy text,svg[data-vector-surface=sequence] text')){
      const box=text.getBoundingClientRect();
      if(box.left<root.left-1||box.right>root.right+1||box.bottom>root.bottom+1)problems.push('Out of image: '+text.textContent);
     }
     for(const text of document.querySelectorAll<SVGGraphicsElement>('svg[data-vector-surface=sequence] text:not(.sequence-index):not(.sequence-note-title),.scene-title,.scene-detail,.scene-label text,[data-heading-role=question] [data-annotation-part=label] text,[data-heading-role=answer] [data-annotation-part=label] text,[data-heading-role=note] text')){
      const matrix=text.getScreenCTM()!,size=parseFloat(getComputedStyle(text).fontSize)*Math.hypot(matrix.a,matrix.b);
      if(size<18)problems.push('Small model label: '+text.textContent+' '+size.toFixed(2));
     }
     for(const annotation of document.querySelectorAll<SVGSVGElement>('svg[data-vector-annotation]')){
      const role=annotation.dataset.headingRole;
      if(role==='question'||role==='answer'){
       const parts=[...annotation.querySelectorAll<SVGGraphicsElement>('[data-annotation-part]')].map(part=>part.getBoundingClientRect());
       for(let i=1;i<parts.length;i++){
        const a=parts[i-1]!,b=parts[i]!;
        if(Math.abs((a.top+a.bottom-b.top-b.bottom)/2)>1)problems.push('Semantic heading misalignment');
        if(a.right+8>b.left)problems.push('Semantic heading crowding');
       }
       if(role==='question'&&(annotation.querySelector('[data-annotation-part=glyph]')||annotation.querySelector('[data-annotation-part=ordinal] text')?.textContent!=='?'))problems.push('Question lost its inquiry marker');
       if(role==='answer'&&(!annotation.querySelector('[data-annotation-part=glyph]')||annotation.querySelector('[data-annotation-part=ordinal]')))problems.push('Answer lost its domain glyph distinction');
      }
      const texts=[...annotation.querySelectorAll<SVGTextElement>('text')];
      for(let i=0;i<texts.length;i++)for(let j=i+1;j<texts.length;j++){
       const a=texts[i]!.getBoundingClientRect(),b=texts[j]!.getBoundingClientRect();
       if(Math.min(a.right,b.right)-Math.max(a.left,b.left)>1&&Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)>1)problems.push('Overlapping text: '+texts[i]!.textContent);
      }
     }
     return problems;
    });
    failures.push(...issues.map(issue=>image.source+': '+issue));
    expect(body).not.toContain('<foreignObject');expect(body).toContain('data-scene-node=');
    await page.screenshot({path:root+'.cache/d2/'+name+'-830.png',fullPage:true});
    await page.setContent('<style>body{margin:0;background:#0d1117}</style><img width="830" src="data:image/svg+xml;base64,'+Buffer.from(body).toString('base64')+'">');
    expect(await page.locator('img').evaluate(async image=>{if(!(image instanceof HTMLImageElement))throw new Error("Not an image");await image.decode();return image.naturalWidth>0;})).toBe(true);
    // Decode as an image, as GitHub does; an inline SVG on white can conceal
    // a transparent root. Sample actual exported pixels, not HTML styling.
    expect(await page.locator('img').evaluate(image=>{
     if(!(image instanceof HTMLImageElement))throw new Error('Not an image');
     const canvas=document.createElement('canvas');canvas.width=canvas.height=4;
     const context=canvas.getContext('2d')!;context.drawImage(image,0,0,4,4);
     return [[0,0],[3,0],[0,3],[3,3]].every(([x,y])=>context.getImageData(x!,y!,1,1).data[3]===255);
    })).toBe(true);
   }finally{await page.close();}
  }
 }finally{await browser.close();}
 expect(failures).toEqual([]);
},30000);
