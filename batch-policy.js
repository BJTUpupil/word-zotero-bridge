(function (scope) {
  'use strict';

  const normalize = value => String(value || '').replaceAll('\\', '/').replace(/\/+$/, '').toLowerCase();
  const absoluteWindowsPath = /^[a-zA-Z]:[\\/]/;

  function validateBatch(batch) {
    if (!batch || typeof batch !== 'object' || Array.isArray(batch)) throw new Error('Invalid batch');
    if (!/^[a-zA-Z0-9_-]{1,80}$/.test(batch.id || '')) throw new Error('Invalid batch ID');
    if (batch.collection !== 'MC8W6IIE') throw new Error('Collection not authorized');
    if (!absoluteWindowsPath.test(batch.projectRoot || '')) throw new Error('projectRoot must be an absolute Windows path');
    if (!absoluteWindowsPath.test(batch.document || '')) throw new Error('document must be an absolute Windows path');

    const projectRoot = normalize(batch.projectRoot);
    const workRoot = projectRoot + '/.word-zotero-bridge/work/';
    const document = normalize(batch.document);
    const filename = document.slice(workRoot.length);
    if (
      !document.startsWith(workRoot) ||
      !/^[a-z0-9][a-z0-9._-]{0,119}\.docx$/.test(filename) ||
      filename.includes('..') ||
      filename.includes(':') ||
      filename.includes('/')
    ) {
      throw new Error('Only a DOCX copy directly under PROJECT/.word-zotero-bridge/work is allowed');
    }

    if (!Array.isArray(batch.jobs) || batch.jobs.length < 1 || batch.jobs.length > 256) {
      throw new Error('Batch must contain 1-256 jobs');
    }
    const ids = new Set();
    for (const job of batch.jobs) {
      if (!job || typeof job !== 'object' || Array.isArray(job)) throw new Error('Invalid job');
      if (
        !/^[a-zA-Z0-9_-]{1,80}$/.test(job.id || '') ||
        job.id === 'final-refresh' ||
        ids.has(job.id)
      ) {
        throw new Error('Invalid or duplicate job ID');
      }
      ids.add(job.id);
      if (!/^[A-Z0-9]{8}$/.test(job.key || '')) throw new Error('Invalid Zotero item key');
      if (typeof job.title !== 'string' || !job.title.trim()) throw new Error('Item title is required');
      if (typeof job.doi !== 'string') throw new Error('Item DOI must be a string');
      if (!job.anchor || typeof job.anchor !== 'object') throw new Error('Job anchor is required');
      if (typeof job.anchor.text !== 'string' || !job.anchor.text) throw new Error('Anchor text is required');
      if (!['before', 'after', 'replace'].includes(job.anchor.position)) throw new Error('Invalid anchor position');
      if (!Number.isInteger(job.anchor.occurrence) || job.anchor.occurrence < 1) {
        throw new Error('Anchor occurrence must be a positive integer');
      }
    }

    return JSON.parse(JSON.stringify({
      id: batch.id,
      collection: batch.collection,
      projectRoot: batch.projectRoot,
      document: batch.document,
      jobs: batch.jobs
    }));
  }

  scope.validateWordZoteroBatch = validateBatch;
})(globalThis);
