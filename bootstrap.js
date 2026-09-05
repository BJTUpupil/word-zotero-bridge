/* Local-only Zotero endpoint. No filesystem channel, library writes, or shell execution. */
var BRIDGE_VERSION = '0.1.0';
var ZOTERO_VERSION = '9.0.6';
var ENDPOINT_PATH = '/word-zotero-bridge/v1/command';
var TARGET_COLLECTION = 'MC8W6IIE';
var MAX_BATCH_JOBS = 256;

var bridgeFactory;
var validateBatch;
var sessionToken;
var endpointConstructor;
var currentBatch = null;
var bridge = null;
var waitingAck = null;
var handling = false;
var disabled = false;
var lastResult = null;

function response(code, value) {
  return [code, 'application/json', JSON.stringify(value)];
}

function publicState() {
  return {
    ok: true,
    version: BRIDGE_VERSION,
    zoteroVersion: Zotero.version,
    endpoint: ENDPOINT_PATH,
    session: sessionToken,
    state: disabled ? 'disabled' : waitingAck ? 'waiting-for-ack' : currentBatch ? 'prepared' : 'ready',
    batchId: currentBatch?.id || null,
    waitingAck,
    lastResult,
    collection: TARGET_COLLECTION,
    maxBatchJobs: MAX_BATCH_JOBS
  };
}

function requireSession(command) {
  if (!command || command.session !== sessionToken) {
    throw new Error('Invalid bridge session');
  }
}

async function validateItems(batch) {
  const libraryID = Zotero.Libraries.userLibraryID;
  const collection = await Zotero.Collections.getByLibraryAndKey(libraryID, TARGET_COLLECTION);
  if (!collection) throw new Error('Target collection is unavailable: ' + TARGET_COLLECTION);
  for (const job of batch.jobs) {
    const item = await Zotero.Items.getByLibraryAndKey(libraryID, job.key);
    if (!item || item.deleted || !item.isRegularItem()) {
      throw new Error('Missing, deleted, or non-parent item: ' + job.key);
    }
    if (!item.getCollections().includes(collection.id)) {
      throw new Error('Item is outside the target collection: ' + job.key);
    }
    const actualTitle = String(item.getField('title') || '').trim().toLowerCase();
    const expectedTitle = job.title.trim().toLowerCase();
    const actualDOI = String(item.getField('DOI') || '').trim().toLowerCase();
    const expectedDOI = job.doi.trim().toLowerCase();
    if (actualTitle !== expectedTitle || actualDOI !== expectedDOI) {
      throw new Error('Item identity changed: ' + job.key);
    }
  }
}

async function handleCommand(command) {
  if (!command || typeof command !== 'object' || Array.isArray(command)) {
    throw new Error('A JSON command object is required');
  }
  if (command.action === 'status') return publicState();
  requireSession(command);

  if (command.action === 'stop') {
    bridge?.stop();
    disabled = true;
    currentBatch = null;
    bridge = null;
    waitingAck = null;
    lastResult = { state: 'stopped' };
    return publicState();
  }
  if (disabled) throw new Error('Bridge is disabled until Zotero restarts');

  if (command.action === 'prepare') {
    if (currentBatch || bridge?.busy) throw new Error('Finish the current batch before preparing another');
    const batch = validateBatch(command.batch);
    await validateItems(batch);
    currentBatch = batch;
    waitingAck = null;
    lastResult = { state: 'prepared', batchId: batch.id, count: batch.jobs.length };
    bridge = bridgeFactory(
      Zotero,
      {...batch, nonce: sessionToken, expiresAt: Date.now() + 30 * 60 * 1000},
      async result => { lastResult = {...result, batchId: batch.id}; }
    );
    return {...publicState(), count: batch.jobs.length};
  }

  if (!bridge || !currentBatch || command.batchId !== currentBatch.id) {
    throw new Error('No matching prepared batch');
  }

  if (command.action === 'ack') {
    if (
      !waitingAck ||
      command.id !== waitingAck ||
      command.verified !== true ||
      !/^[a-f0-9]{64}$/i.test(command.documentSHA256 || '') ||
      !Number.isInteger(command.citationFieldCount) ||
      command.citationFieldCount < 0
    ) {
      throw new Error('Saved-document verification acknowledgement required');
    }
    const completedId = waitingAck;
    lastResult = {
      state: 'acknowledged',
      batchId: currentBatch.id,
      id: completedId,
      documentSHA256: command.documentSHA256.toLowerCase(),
      citationFieldCount: command.citationFieldCount
    };
    waitingAck = null;
    if (completedId === 'final-refresh') {
      currentBatch = null;
      bridge = null;
    }
    return publicState();
  }

  if (waitingAck) throw new Error('Verify and acknowledge the saved document before continuing');
  if (!['insert', 'refresh'].includes(command.action)) throw new Error('Unsupported bridge action');
  if (command.action === 'refresh' && command.id !== 'final-refresh') {
    throw new Error('Refresh requires id=final-refresh');
  }

  const result = await bridge.run({
    nonce: sessionToken,
    action: command.action,
    id: command.id
  });
  lastResult = {...result, batchId: currentBatch.id};
  if (result.state === 'native-complete-unverified') waitingAck = command.id;
  return publicState();
}

async function startup({rootURI}) {
  await Zotero.initializationPromise;
  if (Zotero.version !== ZOTERO_VERSION) {
    throw new Error('Word Zotero Bridge requires Zotero ' + ZOTERO_VERSION);
  }
  const scope = {};
  Services.scriptloader.loadSubScript(rootURI + 'bridge.js', scope);
  Services.scriptloader.loadSubScript(rootURI + 'batch-policy.js', scope);
  bridgeFactory = scope.createWordZoteroBridge;
  validateBatch = scope.validateWordZoteroBatch;
  if (typeof bridgeFactory !== 'function' || typeof validateBatch !== 'function') {
    throw new Error('Bridge modules failed to load');
  }

  sessionToken = Services.uuid.generateUUID().toString().replace(/[{}]/g, '')
    + Services.uuid.generateUUID().toString().replace(/[{}]/g, '');

  endpointConstructor = function () {};
  endpointConstructor.prototype = {
    supportedMethods: ['POST'],
    supportedDataTypes: ['application/json'],
    async init(request) {
      if (handling) return response(409, {ok: false, error: 'Bridge is busy'});
      handling = true;
      try {
        return response(200, await handleCommand(request.data));
      } catch (error) {
        Zotero.logError(error);
        return response(400, {ok: false, error: String(error?.message || error), ...publicState()});
      } finally {
        handling = false;
      }
    }
  };
  Zotero.Server.Endpoints[ENDPOINT_PATH] = endpointConstructor;
  Zotero.debug('Word Zotero Bridge ready at ' + ENDPOINT_PATH);
}

function shutdown() {
  bridge?.stop();
  disabled = true;
  currentBatch = null;
  bridge = null;
  waitingAck = null;
  if (Zotero.Server.Endpoints[ENDPOINT_PATH] === endpointConstructor) {
    delete Zotero.Server.Endpoints[ENDPOINT_PATH];
  }
}

function install() {}
function uninstall() {}
