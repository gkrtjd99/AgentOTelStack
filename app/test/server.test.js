const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');
const { app, createListenHandler } = require('../src');

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
