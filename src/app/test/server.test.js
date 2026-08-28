const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');
const {
  activeTraceID,
  app,
  createListenHandler,
  setOptInTraceIDHeader,
  traceIDHeader,
} = require('../src');

test('response trace IDs are disabled by default and never leak', () => {
  const previous = process.env.AGENTOTEL_EXPOSE_TRACE_ID_HEADER;
  delete process.env.AGENTOTEL_EXPOSE_TRACE_ID_HEADER;
  const headers = new Map();
  const response = { setHeader(name, value) { headers.set(name, value); } };
  const span = { spanContext: () => ({ traceId: '0123456789abcdef0123456789abcdef' }) };

  assert.equal(activeTraceID(span), '');
  assert.equal(setOptInTraceIDHeader(response, span), '');
  assert.equal(headers.has(traceIDHeader), false);
  if (previous === undefined) delete process.env.AGENTOTEL_EXPOSE_TRACE_ID_HEADER;
  else process.env.AGENTOTEL_EXPOSE_TRACE_ID_HEADER = previous;
});

test('opt-in response trace ID is a validated lowercase span trace ID', () => {
  const previous = process.env.AGENTOTEL_EXPOSE_TRACE_ID_HEADER;
  process.env.AGENTOTEL_EXPOSE_TRACE_ID_HEADER = '1';
  const headers = new Map();
  const response = { setHeader(name, value) { headers.set(name, value); } };
  const span = { spanContext: () => ({ traceId: 'ABCDEF0123456789ABCDEF0123456789' }) };
  assert.equal(setOptInTraceIDHeader(response, span), 'abcdef0123456789abcdef0123456789');
  assert.equal(headers.get(traceIDHeader), 'abcdef0123456789abcdef0123456789');

  const invalid = { spanContext: () => ({ traceId: 'not-a-trace' }) };
  headers.clear();
  assert.equal(setOptInTraceIDHeader(response, invalid), '');
  assert.equal(headers.has(traceIDHeader), false);
  if (previous === undefined) delete process.env.AGENTOTEL_EXPOSE_TRACE_ID_HEADER;
  else process.env.AGENTOTEL_EXPOSE_TRACE_ID_HEADER = previous;
});

test('checkout success fixture bypasses the intentional flaky failure path', async () => {
  const server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  const address = server.address();
  const response = await fetch(`http://127.0.0.1:${address.port}/api/checkout?success=1`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: 'paid' });
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
});

test('Express listen errors are logged and set a failing exit code', async () => {
  const blocker = net.createServer();
  await new Promise((resolve) => blocker.listen(0, resolve));
  const port = blocker.address().port;
  const previousExitCode = process.exitCode;
  process.exitCode = undefined;

  const error = await new Promise((resolve) => {
    const logger = {
      error(fields, message) {
        resolve({ fields, message });
      },
      info() {},
    };
    app.listen(port, createListenHandler(logger, port));
  });

  await new Promise((resolve) => blocker.close(resolve));
  process.exitCode = previousExitCode;

  assert.equal(error.message, 'sample-app failed to listen');
  assert.equal(error.fields.err.code, 'EADDRINUSE');
});
