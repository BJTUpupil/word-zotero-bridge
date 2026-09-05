const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const scope = {};
vm.runInNewContext(fs.readFileSync(__dirname + '/batch-policy.js', 'utf8'), scope);

const valid = () => ({
  id: 'batch1',
  collection: 'MC8W6IIE',
  projectRoot: 'G:/paper-project',
  document: 'G:/paper-project/.word-zotero-bridge/work/copy.docx',
  jobs: [{
    id: 'cite1',
    key: 'DFAU8KU8',
    title: 'Paper',
    doi: '10/example',
    anchor: {text: 'anchor', occurrence: 1, position: 'after'}
  }]
});
const check = batch => scope.validateWordZoteroBatch(batch);

assert.equal(check(valid()).jobs.length, 1);
let checks = 1;
for (const path of [
  'G:/paper-project/source.docx',
  'G:/paper-project/.word-zotero-bridge/work/../source.docx',
  'G:/paper-project/.word-zotero-bridge/work/sub/copy.docx',
  'G:/paper-project/.word-zotero-bridge/work/copy.docx:ads',
  'G:/paper-project/.word-zotero-bridge/work/copy.docm',
  'G:/paper-project/.word-zotero-bridge/worked/copy.docx'
]) {
  const batch = valid();
  batch.document = path;
  assert.throws(() => check(batch));
  checks++;
}
for (const mutate of [
  batch => { batch.collection = 'OTHER'; },
  batch => { batch.jobs = []; },
  batch => { batch.jobs[0].key = 'bad'; },
  batch => { batch.jobs[0].title = ''; },
  batch => { batch.jobs.push(batch.jobs[0]); },
  batch => { batch.jobs[0].id = 'final-refresh'; },
  batch => { batch.id = '../ledger'; },
  batch => { batch.projectRoot = 'relative'; },
  batch => { batch.jobs[0].anchor = null; },
  batch => { batch.jobs[0].anchor.position = 'inside'; },
  batch => { batch.jobs[0].anchor.occurrence = 0; }
]) {
  const batch = valid();
  mutate(batch);
  assert.throws(() => check(batch));
  checks++;
}
console.log('PASS', checks, 'batch policy checks');
