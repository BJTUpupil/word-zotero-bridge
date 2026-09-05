/* Native citation-selection adapter. Zotero owns all Word field writes. */
(function (scope) {
  'use strict';
  function createBridge(Z, config, emit, now = Date.now) {
    const I = Z.Integration;
    let busy = false, stopped = false, fatal = false, acceptedCount = 0;
    const used = new Set();
    const expires = Math.min(config.expiresAt, now() + 30 * 60 * 1000);
    const normalize = p => String(p).replaceAll('/', '\\').toLowerCase();
    const reject = message => { throw new Error(message); };
    if (!Array.isArray(config.jobs) || config.jobs.length < 1 || config.jobs.length > 256) reject('Batch must contain 1-256 insertion jobs');
    if (new Set(config.jobs.map(j => j.id)).size !== config.jobs.length) reject('Duplicate job IDs');
    if (config.collection !== 'MC8W6IIE') reject('Collection not authorized');
    async function validate(job) {
      if (Z.version !== '9.0.6') reject('Unsupported Zotero version');
      const collection = await Z.Collections.getByLibraryAndKey(Z.Libraries.userLibraryID, config.collection);
      const item = await Z.Items.getByLibraryAndKey(Z.Libraries.userLibraryID, job.key);
      if (!collection || !item || item.deleted || !item.isRegularItem()) reject('Missing/deleted/non-parent item');
      if (!item.getCollections().includes(collection.id)) reject('Item outside target collection');
      if (item.getField('title').trim().toLowerCase() !== job.title.toLowerCase()) reject('Item title mismatch');
      if (item.getField('DOI').trim().toLowerCase() !== job.doi.toLowerCase()) reject('Item DOI mismatch');
      return item;
    }
    async function run(request) {
      if (busy) return { state: 'busy' };
      if (stopped || fatal || now() >= expires) return { state: 'disabled' };
      if (request?.nonce !== config.nonce) return { state: 'unauthorized' };
      if (request.action === 'stop') { stopped = true; return { state: 'stopped' }; }
      const refresh = request.action === 'refresh' && request.id === 'final-refresh';
      const job = config.jobs.find(j => j.id === request.id);
      if ((!refresh && (request.action !== 'insert' || !job)) || used.has(request.id)) return { state: 'rejected' };
      if (refresh && acceptedCount !== config.jobs.length) return { state: 'rejected' };
      if (!refresh && job !== config.jobs[acceptedCount]) return { state: 'rejected' };
      if (I.currentDoc) return { state: 'integration-busy' };
      // Consumed before native entry: never retry a potentially partial insertion.
      used.add(request.id); busy = true;
      let item, selected = false, failure = null, targetDoc = null;
      const restorations = [];
      function replace(object, name, replacement) {
        const original = object[name];
        if (typeof original !== 'function') reject('Missing native function: ' + name);
        object[name] = replacement;
        restorations.push(() => {
          if (object[name] === replacement) object[name] = original;
          else failure = failure || 'Hook changed concurrently: ' + name;
        });
        return original;
      }
      function abort(message) {
        failure = failure || message;
        throw new Z.Exception.UserCancelled(message);
      }
      try {
        await emit({ id: request.id, state: 'running' });
        if (!refresh) item = await validate(job);
        const nativeExec = I.execCommand;
        const nativeApp = I.getApplication;
        replace(I, 'execCommand', async function () { abort('Concurrent integration command blocked'); });
        replace(I, 'getApplication', function (agent, command, docId) {
          if (agent !== 'WinWord' || normalize(docId) !== normalize(config.document)) abort('Unexpected target document');
          const app = nativeApp.apply(this, arguments);
          const nativeGetDoc = app.getDocument;
          replace(app, 'getDocument', async function (path) {
            if (normalize(path) !== normalize(config.document)) abort('Document path changed');
            targetDoc = await nativeGetDoc.call(this, path);
            // No automatic answers to old-reference/retraction/data-loss prompts.
            replace(targetDoc, 'displayAlert', async function () { abort('Word confirmation required; trial stopped'); });
            return targetDoc;
          });
          if (typeof app.getActiveDocument === 'function') {
            replace(app, 'getActiveDocument', async function () { abort('Active-document fallback forbidden'); });
          }
          return app;
        });
        replace(I, '_handleCommandError', async function (_doc, _session, error) {
          failure = failure || String(error?.message || error);
        });
        replace(I, 'displayDialog', async function (url, options, io, type) {
          const isPicker = url === 'chrome://zotero/content/integration/citationDialog.xhtml' && type === 'citation';
          if (!isPicker) abort('Additional Zotero dialog required: ' + type);
          try {
            if (refresh || selected || I.currentDoc !== targetDoc || !targetDoc) reject('Unexpected citation dialog');
            if (stopped || now() >= expires) reject('Trial expired');
            if (!io?.citation || typeof io.accept !== 'function' || typeof io.cancel !== 'function') reject('Incompatible picker interface');
            if (io.citation.citationItems.length) reject('Cursor is inside an existing citation');
            await io.allCitedDataLoadedPromise;
            if (failure) reject(failure);
            item = await validate(job);
            // Supply only the selection, exactly as the native picker does.
            // Zotero owns serialization, citeproc formatting, and Word field writes.
            io.citation.citationItems = [{ id: item.id }];
            selected = true;
            io.accept();
          } catch (error) {
            failure = String(error?.message || error);
            if (typeof io?.cancel === 'function') io.cancel();
          }
        });
        await nativeExec.call(I, 'WinWord', refresh ? 'refresh' : 'addEditCitation', config.document, 1);
        if (!refresh && !selected) reject('Native citation selection was not reached');
        if (failure) reject(failure);
      } catch (error) {
        failure = failure || String(error?.message || error);
      } finally {
        for (const restore of restorations.reverse()) restore();
        busy = false;
      }
      if (failure) {
        fatal = true;
        const result = { id: request.id, state: 'failed-do-not-retry', error: failure };
        await emit(result); return result;
      }
      if (!refresh) acceptedCount++;
      else stopped = true;
      const result = { id: request.id, state: 'native-complete-unverified', acceptedCount, key: job?.key || null };
      await emit(result); return result;
    }
    return { run, stop() { stopped = true; }, get busy() { return busy; }, get stopped() { return stopped || fatal; } };
  }
  scope.createWordZoteroBridge = createBridge;
})(this);
