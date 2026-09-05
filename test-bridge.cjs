const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const scope = {};
vm.runInNewContext(fs.readFileSync(__dirname + '/bridge.js', 'utf8'), scope);
const factory = scope.createWordZoteroBridge;
let total = 0;
function fixture(options = {}) {
  const events = [];
  const config = { nonce: 'test-nonce', expiresAt: 9999999, collection: 'MC8W6IIE', document: 'G:\\paper-project\\.word-zotero-bridge\\work\\trial.docx', jobs: Array.from({length:options.count || 5}, (_,i) => ({id:'insert-'+(i+1),key:'KEY'+i,title:'Paper '+i,doi:'doi-'+i})) };
  class Cancel extends Error {}
  const doc = {displayAlert:async()=>{}, cleanup:async()=>{}};
  const app = {getDocument:async()=>doc,getActiveDocument:async()=>doc};
  const I = {
    currentDoc: null,
    getApplication:()=>app,
    displayDialog:async()=>{},
    _handleCommandError:async()=>{},
    execCommand: async function(agent, command, path) {
      try {
        const a=I.getApplication(agent,command,options.wrongDoc?'C:\\other.docx':path);
        I.currentDoc=await a.getDocument(path);
        if (options.wordPrompt) await I.currentDoc.displayAlert('question');
        if (command==='refresh') return;
        if (options.otherDialog) { await I.displayDialog('unexpected','',{},'documentPreferences'); return; }
        let resolve;
        const promise=new Promise(r=>resolve=r);
        const io={citation:{citationItems:options.existing?[{id:99}]:[]},allCitedDataLoadedPromise:Promise.resolve(),accept(){resolve();},cancel(){this.citation.citationItems=[];resolve();}};
        I.displayDialog('chrome://zotero/content/integration/citationDialog.xhtml','',io,'citation');
        await promise;
        events.push({selected:io.citation.citationItems.map(x=>x.id)});
      } catch(e) { await I._handleCommandError(doc,null,e); }
      finally { I.currentDoc=null; }
    }
  };
  const Z={version:options.version||'9.0.6',Integration:I,Exception:{UserCancelled:Cancel},Libraries:{userLibraryID:1},Collections:{getByLibraryAndKey:async()=>({id:7})},Items:{getByLibraryAndKey:async(_l,key)=>{
    const n=Number(key.slice(3));
    return {id:100+n,deleted:!!options.deleted,isRegularItem:()=>true,getCollections:()=>options.outside?[8]:[7],getField:f=>f==='title'?(options.wrongTitle?'other':'Paper '+n):'doi-'+n};
  }}};
  const before={...I};
  const bridge=factory(Z,config,async e=>events.push(e),()=>options.expired?99999999:1000);
  const req=(n)=>({nonce:config.nonce,action:'insert',id:'insert-'+n});
  return {bridge,config,I,events,before,req,doc,app};
}
async function test(name, fn) {await fn(); total++; console.log('PASS',name);}
(async()=>{
 await test('five fixed items; native refresh; stop afterwards',async()=>{
   const f=fixture();
   for(let n=1;n<=5;n++) assert.equal((await f.bridge.run(f.req(n))).state,'native-complete-unverified');
   assert.deepEqual(f.events.filter(e=>e.selected).map(e=>e.selected[0]),[100,101,102,103,104]);
   assert.equal((await f.bridge.run({nonce:'test-nonce',id:'final-refresh',action:'refresh'})).state,'native-complete-unverified');
   assert.equal((await f.bridge.run(f.req(1))).state,'disabled');
 });
 await test('invalid credential and unknown key do not invoke native integration',async()=>{
   const f=fixture(); assert.equal((await f.bridge.run({...f.req(1),nonce:'bad'})).state,'unauthorized');
   assert.equal((await f.bridge.run({...f.req(1),id:'arbitrary'})).state,'rejected'); assert.equal(f.events.length,0);
 });
 await test('duplicate job is never inserted twice',async()=>{
   const f=fixture(); await f.bridge.run(f.req(1)); assert.equal((await f.bridge.run(f.req(1))).state,'rejected');
   assert.equal(f.events.filter(e=>e.selected).length,1);
 });
 for(const option of ['outside','deleted','wrongTitle','wrongDoc','existing','wordPrompt','otherDialog']) {
   await test(option+' fails closed and restores hooks',async()=>{
     const f=fixture({[option]:true}); assert.equal((await f.bridge.run(f.req(1))).state,'failed-do-not-retry');
     for(const name of ['execCommand','displayDialog','getApplication','_handleCommandError']) assert.equal(f.I[name],f.before[name]);
     assert.equal((await f.bridge.run(f.req(2))).state,'disabled');
   });
 }
 await test('unsupported runtime version is rejected',async()=>{
   const f=fixture({version:'9.0.7'}); assert.equal((await f.bridge.run(f.req(1))).state,'failed-do-not-retry');
 });
 await test('expiry blocks all document operations',async()=>{
   const f=fixture({expired:true}); assert.equal((await f.bridge.run(f.req(1))).state,'disabled'); assert.equal(f.events.length,0);
 });
 await test('active user integration is left untouched',async()=>{
   const f=fixture(); f.I.currentDoc={}; assert.equal((await f.bridge.run(f.req(1))).state,'integration-busy'); assert.equal(f.I.execCommand,f.before.execCommand);
 });
 await test('refresh before all five jobs is rejected',async()=>{
   const f=fixture(); assert.equal((await f.bridge.run({nonce:'test-nonce',id:'final-refresh',action:'refresh'})).state,'rejected');
 });
 await test('concurrent request does not select another item',async()=>{
   const f=fixture(); const pending=f.bridge.run(f.req(1)); assert.equal((await f.bridge.run(f.req(2))).state,'busy'); await pending;
 });
 await test('55 insertion jobs and one final native refresh',async()=>{
   const f=fixture({count:55});
   for(let n=1;n<=55;n++) assert.equal((await f.bridge.run(f.req(n))).state,'native-complete-unverified');
   assert.equal(f.events.filter(e=>e.selected).length,55);
   assert.equal((await f.bridge.run({nonce:'test-nonce',id:'final-refresh',action:'refresh'})).state,'native-complete-unverified');
 });
 await test('64 citation locations are supported',async()=>{
   const f=fixture({count:64});
   for(let n=1;n<=64;n++) assert.equal((await f.bridge.run(f.req(n))).state,'native-complete-unverified');
   assert.equal(f.events.filter(e=>e.selected).length,64);
 });
 await test('out-of-order jobs cannot consume a citation position',async()=>{
   const f=fixture(); assert.equal((await f.bridge.run(f.req(2))).state,'rejected'); assert.equal(f.events.length,0);
   assert.equal((await f.bridge.run(f.req(1))).state,'native-complete-unverified');
 });
 await test('oversized batch rejected at creation',async()=>assert.throws(()=>fixture({count:257}),/1-256/));
 console.log('TOTAL',total,'mock contract checks passed; live Word/Zotero NOT tested');
})().catch(e=>{console.error(e);process.exitCode=1;});
