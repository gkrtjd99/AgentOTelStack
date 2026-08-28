const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const createRequestState = require('./static/assets/request-state.js');
const validClientToken = ('01234567' + '89abcdef').repeat(4);

function luminance(hex) {
  const channels = hex.match(/[0-9a-f]{2}/gi).map((value) => parseInt(value, 16) / 255);
  const linear = channels.map((value) => value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrast(foreground, background) {
  const light = Math.max(luminance(foreground), luminance(background));
  const dark = Math.min(luminance(foreground), luminance(background));
  return (light + 0.05) / (dark + 0.05);
}

test('a newer view request aborts and supersedes an older delayed response', () => {
  const requests = createRequestState();
  const first = requests.begin('errors');
  const second = requests.begin('errors');
  assert.equal(first.controller.signal.aborted, true);
  assert.equal(requests.current('errors', first), false);
  assert.equal(requests.current('errors', second), true);

  const rendered = [];
  if (requests.current('errors', first)) rendered.push('old');
  if (requests.current('errors', second)) rendered.push('new');
  assert.deepEqual(rendered, ['new']);
});

test('requests in different views do not cancel one another', () => {
  const requests = createRequestState();
  const overview = requests.begin('overview');
  const errors = requests.begin('errors');
  assert.equal(requests.current('overview', overview), true);
  assert.equal(requests.current('errors', errors), true);
});

test('a delayed overview response cannot apply after navigating to services', () => {
  const requests = createRequestState();
  const overview = requests.begin('overview');
  const services = requests.begin('services');
  assert.equal(requests.current('overview', overview, 'services'), false);
  assert.equal(requests.current('services', services, 'services'), true);
  const visibleUpdates = [];
  if (requests.current('overview', overview, 'services')) visibleUpdates.push('overview');
  if (requests.current('services', services, 'services')) visibleUpdates.push('services');
  assert.deepEqual(visibleUpdates, ['services']);
});

test('dashboard client tokens require exact lowercase 64-hex values', () => {
  const requests = createRequestState();
  assert.equal(requests.validClientToken(validClientToken), true);
  assert.equal(requests.validClientToken(validClientToken.slice(0, -1)), false);
  assert.equal(requests.validClientToken(`${validClientToken.slice(0, -1)}F`), false);
  assert.equal(requests.validClientToken(''), false);
});

test('valid bootstrap token is scrubbed without persistence', () => {
  const requests = createRequestState();
  let scrubbed = 0;
  const token = validClientToken;
  const result = requests.bootstrapToken(`#token=${token}`, () => { scrubbed += 1; });
  assert.deepEqual(result, { attempted: true, token });
  assert.equal(scrubbed, 1);
  assert.equal(Object.prototype.hasOwnProperty.call(globalThis, 'localStorage'), false);
  assert.equal(Object.prototype.hasOwnProperty.call(globalThis, 'sessionStorage'), false);
});

test('missing or malformed bootstrap token fails closed', () => {
  const requests = createRequestState();
  for (const hash of ['#overview', '#token=bad', `#token=${validClientToken.slice(0, -1)}F`]) {
    const result = requests.bootstrapToken(hash, () => {});
    assert.equal(result.token, '');
    assert.equal(result.attempted, hash.startsWith('#token='));
  }
});

test('dark primary button contrast meets WCAG AA', () => {
  const styles = fs.readFileSync(path.join(__dirname, 'static/assets/styles.css'), 'utf8');
  const darkBlock = styles.match(/:root\[data-theme="dark"\] \{([\s\S]*?)\n\}/);
  assert.ok(darkBlock, 'dark theme token block is present');
  const foreground = darkBlock[1].match(/--button-foreground:\s*(#[0-9a-f]{6})/i);
  const background = darkBlock[1].match(/--button-background:\s*(#[0-9a-f]{6})/i);
  assert.ok(foreground && background, 'dark button tokens are present');
  assert.ok(contrast(foreground[1], background[1]) >= 4.5, `contrast ${contrast(foreground[1], background[1])}`);
});
