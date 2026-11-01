import {test,expect} from 'bun:test';
import {chromium} from 'playwright';
import {fileURLToPath} from 'node:url';
import {readFile} from 'node:fs/promises';
const root=fileURLToPath(new URL('../../../',import.meta.url));

test('standalone README SVGs retain legible fonts, vector icons and complete text at GitHub width',async()=>{
 const browser=await chromium.launch();
 try{
  for(const name of ['00a-readme-overview','00c-readme-assurance','00d-zero-trust-overview']){
   const body=await readFile(root+'docs/architecture/diagrams/'+name+'.svg','utf8');
   const page=await browser.newPage({viewport:{width:830,height:1000}});
   try{
    await page.setContent('<style>body{margin:0}body>svg{width:830px;height:auto}</style>'+body);
    await page.evaluate(()=>document.fonts.ready);
    const issues=await page.evaluate(()=>{
     const problems:string[]=[],root=document.querySelector('body>svg')!.getBoundingClientRect();
     for(const text of document.querySelectorAll<SVGTextElement>('svg[data-vector-annotation] text,.scene-copy text')){
      const box=text.getBoundingClientRect();
      if(box.left<root.left-1||box.right>root.right+1||box.bottom>root.bottom+1)problems.push('Out of image: '+text.textContent);
     }
     for(const text of document.querySelectorAll<SVGTSpanElement>('.scene-title,.scene-detail')){
      const matrix=text.getScreenCTM()!,size=parseFloat(getComputedStyle(text).fontSize)*Math.hypot(matrix.a,matrix.b);
      if(size<18)problems.push('Small model label: '+text.textContent+' '+size.toFixed(2));
     }
     for(const annotation of document.querySelectorAll<SVGSVGElement>('svg[data-vector-annotation]')){
      const texts=[...annotation.querySelectorAll<SVGTextElement>('text')];
      for(let i=0;i<texts.length;i++)for(let j=i+1;j<texts.length;j++){
       const a=texts[i]!.getBoundingClientRect(),b=texts[j]!.getBoundingClientRect();
       if(Math.min(a.right,b.right)-Math.max(a.left,b.left)>1&&Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)>1)problems.push('Overlapping text: '+texts[i]!.textContent);
      }
     }
     return problems;
    });
    expect(issues).toEqual([]);
    expect(body).not.toContain('<foreignObject');expect(body).toContain('data-source-node=');
    await page.screenshot({path:root+'.cache/d2/'+name+'-830.png',fullPage:true});
    await page.setContent('<img width="830" src="data:image/svg+xml;base64,'+Buffer.from(body).toString('base64')+'">');
    expect(await page.locator('img').evaluate(async image=>{if(!(image instanceof HTMLImageElement))throw new Error("Not an image");await image.decode();return image.naturalWidth>0;})).toBe(true);
   }finally{await page.close();}
  }
 }finally{await browser.close();}
},30000);
