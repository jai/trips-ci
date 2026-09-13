import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

// Execute the production github-script block with API responses under test.
const workflow = readFileSync(new URL('../.github/workflows/pull-request-validation.yaml', import.meta.url), 'utf8');
const lines = workflow.split('\n');
const start = lines.findIndex((line) => /^\s+script: \|$/.test(line));
assert.notEqual(start, -1, 'production validation script must exist');
const indent = lines[start].search(/\S/) + 2;
const body = [];
for (const line of lines.slice(start + 1)) {
  if (line.trim() && line.search(/\S/) < indent) break;
  body.push(line.slice(indent));
}
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const validate = new AsyncFunction('github', 'context', 'core', body.join('\n'));
const validBody = '## Summary\nFix metadata validation.\n\n## Related Issue\nNone: This changes only delivery automation.\n\n## Validation\nExecutable regression checks passed.';
const validPR = { number: 177, title: 'fix: validate current metadata', body: validBody, user: { login: 'jai' } };

async function check(eventPR, currentPR, fetchError) {
  const failures = [];
  const requests = [];
  const github = { rest: { pulls: { get: async (request) => {
    requests.push(request);
    if (fetchError) throw fetchError;
    return { data: currentPR };
  } } } };
  const context = { repo: { owner: 'jai', repo: 'trips-ci' }, payload: { pull_request: eventPR } };
  const core = { notice() {}, info() {}, setFailed(message) { failures.push(message); } };
  await validate(github, context, core);
  return { failures, requests };
}

test('a stale empty body cannot reject the currently valid PR', async () => {
  const result = await check({ ...validPR, body: '' }, validPR);
  assert.deepEqual(result.failures, []);
  assert.deepEqual(result.requests, [{ owner: 'jai', repo: 'trips-ci', pull_number: 177 }]);
});

test('a stale valid body cannot approve the currently empty PR', async () => {
  const result = await check(validPR, { ...validPR, body: '' });
  assert.equal(result.failures.length, 1);
  assert.match(result.failures[0], /PR body is empty/);
});

test('a stale release title cannot exempt a current feature PR', async () => {
  const result = await check({ ...validPR, title: 'release: old title', body: '' }, { ...validPR, body: '' });
  assert.equal(result.failures.length, 1);
});

test('the current release title keeps its existing body exemption', async () => {
  const result = await check({ ...validPR, body: '' }, { ...validPR, title: 'release: current title', body: '' });
  assert.deepEqual(result.failures, []);
});

test('API failure cannot fall back to stale valid metadata', async () => {
  await assert.rejects(check(validPR, validPR, new Error('API unavailable')), /API unavailable/);
});

test('non-PR invocations remain a no-op', async () => {
  assert.deepEqual(await check(undefined, undefined), { failures: [], requests: [] });
});
