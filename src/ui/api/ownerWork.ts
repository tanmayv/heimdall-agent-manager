import { parseOwnerRequestDocument } from './ownerJson.ts';

const object=(v:any):v is Record<string,any>=>v!==null && typeof v==='object' && !Array.isArray(v);
const keys=(v:any,names:string)=>Object.keys(v).every(k=>names.split('|').includes(k));
const bytes=(s:string)=>new TextEncoder().encode(s).length;
const id=(v:any)=>typeof v==='string' && /^[a-zA-Z0-9_.:-]{1,160}$/.test(v);
const ref=(v:any)=>object(v) && Object.keys(v).length===2 && ['task','workflow_run'].includes(v.kind) && id(v.id);
const reason=(v:any)=>typeof v==='string' && v.trim()!=='';
const counter=(v:any)=>typeof v==='string' && /^(0|[1-9][0-9]*)$/.test(v) && v.length<=19 && BigInt(v)<=9223372036854775807n;
export const ownerWorkMethods=new Set(['chain.draft','chain.publish','task.publish','chain.propose','chain.decide','chain.complete','work.dependency.add','work.dependency.remove','work.scope']);

// Request validation only. The Bridge revalidates briefs, inputs and graph state.
export function ownerWorkDocumentValid(raw:string,method:string):boolean {
  try {
    if(bytes(raw)>256*1024)return false;
    const o:any=parseOwnerRequestDocument(raw);
    if(!object(o))return false;
    switch(method){
      case 'chain.draft':case 'chain.publish':case 'task.publish':return Object.keys(o).length===0;
      case 'chain.decide':return Object.keys(o).length===3 && keys(o,'proposal_id|decision|note') && id(o.proposal_id) && ['approve','reject'].includes(o.decision) && typeof o.note==='string' && bytes(o.note)<=8192;
      case 'chain.complete':return Object.keys(o).length===2 && keys(o,'expected_work_revision|summary') && counter(o.expected_work_revision) && reason(o.summary) && bytes(o.summary)<=8192;
      case 'work.dependency.add':return Object.keys(o).length===3 && keys(o,'dependency_id|dependent|prerequisite') && id(o.dependency_id) && ref(o.dependent) && ref(o.prerequisite);
      case 'work.dependency.remove':return Object.keys(o).length===2 && keys(o,'dependency_id|reason') && id(o.dependency_id) && reason(o.reason);
      case 'work.scope':return Object.keys(o).length===3 && keys(o,'item|action|reason') && ref(o.item) && ['include','exclude'].includes(o.action) && reason(o.reason);
      case 'chain.propose': {
        if(!keys(o,'kind|tasks|rationale|alternative|auto_approve|workflow|inputs') || !['task','workflow_run'].includes(o.kind))return false;
        for(const name of ['rationale','alternative','workflow'])if(Object.hasOwn(o,name) && typeof o[name]!=='string')return false;
        if(Object.hasOwn(o,'auto_approve') && typeof o.auto_approve!=='boolean')return false;
        if(Object.hasOwn(o,'inputs') && !object(o.inputs))return false;
        if(Object.hasOwn(o,'tasks')){
          if(!Array.isArray(o.tasks) || o.tasks.length>32 || (o.kind==='workflow_run' && o.tasks.length))return false;
          for(const s of o.tasks){
            if(!object(s) || !keys(s,'id|task_id|title|description|priority|brief|goal|acceptance|role|depends_on') || !reason(s.title) || bytes(s.title)>8192)return false;
            for(const n of ['id','task_id','description','priority','goal','role','title'])if(Object.hasOwn(s,n) && typeof s[n]!=='string')return false;
            for(const n of ['id','task_id'])if(s[n]!==undefined && s[n]!=='' && !id(s[n]))return false;
            if(s.id && s.task_id && s.id!==s.task_id)return false;
            if(s.priority && !['p0','p1','p2'].includes(s.priority))return false;
            if(Object.hasOwn(s,'brief') && !object(s.brief))return false;
            for(const n of ['acceptance','depends_on'])if(Object.hasOwn(s,n) && (!Array.isArray(s[n]) || s[n].length>100 || s[n].some((v:any)=>typeof v!=='string')))return false;
          }
        }
        return o.kind==='workflow_run'?typeof o.workflow==='string' && o.workflow!=='':!o.workflow && !Object.hasOwn(o,'inputs');
      }
      default:return false;
    }
  }catch{return false;}
}
