const test = require('node:test');
const assert = require('node:assert/strict');
const { BatchLogRecordProcessor } = require('@opentelemetry/sdk-logs');
const { SeverityNumber } = require('@opentelemetry/api-logs');

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
