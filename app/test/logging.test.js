const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const pino = require('pino');
const { BatchLogRecordProcessor } = require('@opentelemetry/sdk-logs');
const { SeverityNumber } = require('@opentelemetry/api-logs');
const { pathnameOnly, safeReq } = require('../src/safe-request');

test('request logging keeps pathname and redacts query parameters', () => {
  const request = safeReq({ method: 'GET', url: '/api/checkout?fail=1&token=secret' });
  assert.deepEqual(request, { method: 'GET', url: '/api/checkout' });
  assert.equal(pathnameOnly('https://example.test/a/b?password=secret#fragment'), '/a/b');
  assert.doesNotMatch(JSON.stringify(request), /fail|token|secret/);
});

test('stdout request record never contains query parameters', () => {
  let output = '';
  const logger = pino({ serializers: { req: safeReq } }, { write: (chunk) => { output += chunk; } });
  logger.info({ req: { method: 'GET', url: '/api/checkout?token=secret' } }, 'request');
  assert.match(output, /"url":"\/api\/checkout"/);
  assert.doesNotMatch(output, /token|secret/);
});

test('collector telemetry contract strips URL queries and bounds metric labels', () => {
  const config = fs.readFileSync(path.join(__dirname, '../../otel-collector/config.yaml'), 'utf8');
  assert.ok(config.includes('replace_pattern(attributes["http.url"], "[?#].*$"'));
  assert.match(config, /keep_keys\(attributes, \["outcome"\]\)/);
});

test('BatchLogRecordProcessor accepts an exporter option and flushes records', async () => {
  const exported = [];
  let shutdowns = 0;
  const exporter = {
    export(records, callback) {
      exported.push(...records);
      callback({ code: 0 }); // ExportResultCode.SUCCESS
    },
    forceFlush: async () => {},
    shutdown: async () => { shutdowns += 1; },
  };
  const processor = new BatchLogRecordProcessor({
    exporter,
    scheduledDelayMillis: 60_000,
  });
  const record = {
    body: 'checkout failed',
    severityText: 'error',
    severityNumber: SeverityNumber.ERROR,
    attributes: { trace_id: '0123456789abcdef0123456789abcdef', span_id: '0123456789abcdef' },
    resource: { asyncAttributesPending: false },
  };

  processor.onEmit(record);
  await processor.forceFlush();
  await processor.shutdown();

  assert.equal(exported.length, 1);
  assert.equal(exported[0].body, 'checkout failed');
  assert.equal(exported[0].severityText, 'error');
  assert.equal(exported[0].attributes.trace_id.length, 32);
  assert.equal(exported[0].attributes.span_id.length, 16);
  assert.equal(shutdowns, 1);
});
