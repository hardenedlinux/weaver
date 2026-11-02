import type {FigureModel} from '@deterministic-engineering/render';

type Subject=FigureModel['subjects'][number];
type Relation=FigureModel['relations'][number];
export interface SequenceModel {
 readonly actors:readonly Subject[];
 readonly messages:readonly Relation[];
 readonly lifelines:readonly Relation[];
 readonly notes:readonly {subject:Subject;owner:Subject}[];
}
const record=(value:unknown):Record<string,unknown>=>{
 if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('Expected sequence presentation');
 return value as Record<string,unknown>;
};
const refs=(value:unknown):string[]=>{
 if(!Array.isArray(value)||value.some(item=>typeof item!=='string'||!item))throw new Error('Expected sequence references');
 if(new Set(value).size!==value.length)throw new Error('Duplicate sequence reference');
 return value as string[];
};

/** A selected schedule over the official D2 capture, never a dependency reflow. */
export function sequenceModel(model:FigureModel|undefined,presentation:unknown):SequenceModel {
 if(!model)throw new Error('Sequence requires the captured D2 model');
 const value=record(presentation),actors=refs(value.actors),messages=refs(value.messages),lifelines=refs(value.lifelines);
 if(!actors.length)throw new Error('Sequence requires participants');
 const subjects=new Map(model.subjects.map(subject=>[subject.id,subject]));
 const relations=new Map(model.relations.map(relation=>[relation.id,relation]));
 if(subjects.size!==model.subjects.length||relations.size!==model.relations.length)throw new Error('Duplicate captured identity');
 const subject=(id:string):Subject=>{const found=subjects.get(id);if(!found)throw new Error('Missing sequence subject: '+id);return found;};
 const relation=(id:string):Relation=>{const found=relations.get(id);if(!found)throw new Error('Missing sequence relation: '+id);return found;};
 const actorSet=new Set(actors),messageSet=new Set(messages);
 const selectedMessages=messages.map(relation),selectedLifelines=lifelines.map(relation);
 if(messages.some(id=>lifelines.includes(id))||messages.length+lifelines.length!==relations.size)throw new Error('Unaccounted sequence relation');
 if(selectedMessages.some(edge=>!actorSet.has(edge.src)||!actorSet.has(edge.dst)))throw new Error('Message endpoint is not a participant');
 if(selectedLifelines.length!==actors.length||new Set(selectedLifelines.map(edge=>edge.src)).size!==actors.length||
    selectedLifelines.some(edge=>!actorSet.has(edge.src)||subjects.has(edge.dst)||edge.label||edge.srcArrow!=='none'||edge.dstArrow!=='none'))throw new Error('Invalid captured lifeline');
 const sourceOrder=model.relations.filter(edge=>messageSet.has(edge.id)).map(edge=>edge.id);
 if(sourceOrder.some((id,index)=>id!==messages[index]))throw new Error('Sequence declaration changes source message order');
 const notes=Object.entries(record(value.notes)).map(([id,owner])=>{
  if(typeof owner!=='string'||!actorSet.has(owner)||actorSet.has(id))throw new Error('Invalid sequence note owner');
  return {subject:subject(id),owner:subject(owner)};
 });
 if(actors.length+notes.length!==subjects.size)throw new Error('Unaccounted sequence subject');
 return {actors:actors.map(subject),messages:selectedMessages,lifelines:selectedLifelines,notes};
}

export function textLines(value:string,width:number):string[] {
 const limit=Math.max(12,Math.floor(width/20));
 return value.replaceAll('\\n','\n').split('\n').flatMap(paragraph=>{
  const lines:string[]=[];let line='';
  for(const word of paragraph.split(/\s+/)){if(line&&line.length+word.length+1>limit){lines.push(line);line=word;}else line+=(line?' ':'')+word;}
  lines.push(line);return lines;
 });
}
