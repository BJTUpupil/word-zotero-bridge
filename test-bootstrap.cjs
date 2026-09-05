const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

let checks = 0;

async function fixture() {
  const selected = [];
  let uuid = 0;
  const scope = {
    console,
    Date,
    JSON,
    Error,
    String,
    Object,
    Array,
    Number,
    RegExp,
    Services: {
      uuid: {generateUUID: () => ({toString: () => '{session-' + (++uuid) + '}'})},
      scriptloader: {
        loadSubScript(url, target) {
          if (url.endsWith('batch-policy.js')) {
            vm.runInNewContext(fs.readFileSync(__dirname + '/batch-policy.js', 'utf8'), target);
          } else {
            target.createWordZoteroBridge = (_z, config, emit) => ({
              busy: false,
              stop() { this.stopped = true; },
              async run(request) {
                selected.push(request.id);
                const result = {state: 'native-complete-unverified', id: request.id};
                await emit(result);
                return result;
              }
            });
          }
        }
      }
    },
    Zotero: {
      version: '9.0.6',
      initializationPromise: Promise.resolve(),
      Server: {Endpoints: {}},
      Libraries: {userLibraryID: 1},
      Collections: {async getByLibraryAndKey() { return {id: 7}; }},
      Items: {
        async getByLibraryAndKey(_library, key) {
          return {
            deleted: false,
            isRegularItem: () => true,
            getCollections: () => [7],
            getField: field => field === 'title' ? 'Paper ' + key : 'doi-' + key
          };
        }
      },
      logError() {},
      debug() {}
    }
  };
  vm.createContext(scope);
  vm.runInContext(fs.readFileSync(__dirname + '/bootstrap.js', 'utf8'), scope);
  await scope.startup({resourceURI: {spec: 'file://fixture/'}});
  const Endpoint = scope.Zotero.Server.Endpoints['/word-zotero-bridge/v1/command'];
  const endpoint = new Endpoint();
  async function call(command) {
    const result = await endpoint.init({data: command});
    return {code: result[0], body: JSON.parse(result[2])};
  }
  const status = (await call({action: 'status'})).body;
  const batch = (id = 'batch1', length = 5) => ({
    id,
    collection: 'MC8W6IIE',
    projectRoot: 'G:/paper-project',
    document: 'G:/paper-project/.word-zotero-bridge/work/' + id + '.docx',
    jobs: Array.from({length}, (_, index) => {
      const key = String(index).padStart(8, '0');
      return {
        id: 'job-' + index,
        key,
        title: 'Paper ' + key,
        doi: 'doi-' + key,
        anchor: {text: '[[ZCITE:job-' + index + ']]', occurrence: 1, position: 'replace'}
      };
    })
  });
  return {scope, selected, call, session: status.session, batch};
}

async function test(name, run) {
  await run();
  checks++;
  console.log('PASS', name);
}

(async () => {
  await test('registers local POST endpoint and returns an idle session', async () => {
    const f = await fixture();
    const result = await f.call({action: 'status'});
    assert.equal(result.code, 200);
    assert.equal(result.body.state, 'ready');
    assert.equal(result.body.collection, 'MC8W6IIE');
    assert.ok(result.body.session);
  });

  await test('registers a diagnostic health endpoint when resourceURI supplies the module root', async () => {
    const f = await fixture();
    const Health = f.scope.Zotero.Server.Endpoints['/word-zotero-bridge/v1/health'];
    const result = await new Health().init({data: {}});
    assert.equal(result[0], 200);
    const body = JSON.parse(result[2]);
    assert.equal(body.state, 'ready');
    assert.equal(body.step, 'complete');
  });

  await test('rejects mutation commands with a wrong session', async () => {
    const f = await fixture();
    const result = await f.call({action: 'prepare', session: 'wrong', batch: f.batch()});
    assert.equal(result.code, 400);
    assert.match(result.body.error, /session/);
  });

  await test('preflights 55 items and requires an acknowledgement after each operation', async () => {
    const f = await fixture();
    const batch = f.batch('large', 55);
    let result = await f.call({action: 'prepare', session: f.session, batch});
    assert.equal(result.body.state, 'prepared');
    for (const job of batch.jobs) {
      result = await f.call({action: 'insert', session: f.session, batchId: batch.id, id: job.id});
      assert.equal(result.body.state, 'waiting-for-ack');
      const blocked = await f.call({action: 'insert', session: f.session, batchId: batch.id, id: job.id});
      assert.equal(blocked.code, 400);
      result = await f.call({
        action: 'ack',
        session: f.session,
        batchId: batch.id,
        id: job.id,
        verified: true,
        documentSHA256: 'a'.repeat(64),
        citationFieldCount: 71
      });
      assert.equal(result.body.state, 'prepared');
    }
    result = await f.call({action: 'refresh', session: f.session, batchId: batch.id, id: 'final-refresh'});
    assert.equal(result.body.state, 'waiting-for-ack');
    result = await f.call({
      action: 'ack',
      session: f.session,
      batchId: batch.id,
      id: 'final-refresh',
      verified: true,
      documentSHA256: 'b'.repeat(64),
      citationFieldCount: 126
    });
    assert.equal(result.body.state, 'ready');
    assert.equal(f.selected.length, 56);
  });

  await test('rejects items outside the authorized collection', async () => {
    const f = await fixture();
    f.scope.Zotero.Items.getByLibraryAndKey = async () => ({
      deleted: false,
      isRegularItem: () => true,
      getCollections: () => [8],
      getField: () => ''
    });
    const result = await f.call({action: 'prepare', session: f.session, batch: f.batch()});
    assert.equal(result.code, 400);
    assert.match(result.body.error, /outside/);
  });

  await test('stop disables the bridge until restart and shutdown unregisters the endpoint', async () => {
    const f = await fixture();
    const result = await f.call({action: 'stop', session: f.session});
    assert.equal(result.body.state, 'disabled');
    f.scope.shutdown();
    assert.equal(f.scope.Zotero.Server.Endpoints['/word-zotero-bridge/v1/command'], undefined);
    assert.equal(f.scope.Zotero.Server.Endpoints['/word-zotero-bridge/v1/health'], undefined);
  });

  console.log('TOTAL', checks, 'bootstrap endpoint checks; live Word/Zotero not tested');
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
