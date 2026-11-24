#!/usr/bin/env node
/*
 * Offline unit tests for the JavaScript in the cymbal-ge-demo Apigee bundles.
 * Runs each policy's script exactly as bundled (lib via IncludeURL + resource) inside a vm sandbox with a
 * minimal Apigee `context` shim, and simulates the ProxyEndpoint step order for the MCP server.
 * Usage: node apigee/tests/run-tests.js     (exit 0 = all pass)
 */
'use strict';
var fs = require('fs');
var path = require('path');
var vm = require('vm');
var assert = require('assert');

var A = path.resolve(__dirname, '..');
function src(bundle, file) {
  return fs.readFileSync(path.join(A, bundle, 'apiproxy', 'resources', 'jsc', file), 'utf8');
}

/** Executes includes + resource like an Apigee Javascript policy, against a variable map. */
function runPolicy(bundle, includes, resource, vars) {
  var ctx = {
    getVariable: function (k) { return Object.prototype.hasOwnProperty.call(vars, k) ? vars[k] : null; },
    setVariable: function (k, v) { vars[k] = v; },
    removeVariable: function (k) { delete vars[k]; }
  };
  var code = includes.map(function (f) { return src(bundle, f); }).join('\n;\n') + '\n;\n' + src(bundle, resource);
  vm.runInNewContext(code, { context: ctx }, { filename: bundle + '/' + resource, timeout: 1000 });
  return vars;
}

var passed = 0;
var failed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
    console.log('  ok   ' + name);
  } catch (e) {
    failed++;
    console.log('  FAIL ' + name + '\n       ' + (e && e.message));
  }
}

// ============================================================================ MCP (simulated pipeline)
var MCPB = 'cymbal-ge-demo-mcp-banking';
var LIB = ['mcp-lib.js'];
var PRODUCTS = {
  internal: { allowed_tools: 'get_account_balance list_transactions transfer_funds get_account_summary get_fx_rate', user_token_required: 'true', quota: 600 },
  partner: { allowed_tools: 'get_account_summary get_fx_rate', user_token_required: 'false', quota: 5 }
};
// act = RFC 8693 actor claim as VerifyJWT exposes a map claim (JSON string); RM Agent's app by default.
var RM_ACT = JSON.stringify({ sub: 'cymbal-ge-demo-agent-app', agent: 'rm-agent', name: 'RM Agent' });
var USERS = {
  alice: { sub: 'rm-alice', role: 'relationship_manager', scope: 'accounts:read payments:write', transfer_limit: '100000', exp: '1999999999', act: RM_ACT },
  bob: { sub: 'teller-bob', role: 'teller', scope: 'accounts:read payments:write', transfer_limit: '10000', exp: '1999999999', act: RM_ACT },
  aliceNoAct: { sub: 'rm-alice', role: 'relationship_manager', scope: 'accounts:read payments:write', transfer_limit: '100000', exp: '1999999999' }
};
var APP_FOR = { internal: 'cymbal-ge-demo-agent-app', partner: 'cymbal-ge-demo-finpal-app' };
var quotaUsed = {};

function errorFlow(vars) {
  runPolicy(MCPB, LIB, 'build-error.js', vars);
  return {
    status: Number(vars['cymbal.err_status']),
    headers: { 'x-cymbal-decided-by': 'apigee', 'x-cymbal-policy': vars['cymbal.err_policy'] },
    body: vars['cymbal.err_body'] ? JSON.parse(vars['cymbal.err_body']) : null,
    raw: vars['cymbal.err_body']
  };
}

/** Mirrors proxies/default.xml PreFlow order. opts: {verb, body, product, user, badToken, appId} */
function mcpCall(opts) {
  var vars = { 'request.verb': opts.verb || 'POST', 'proxy.pathsuffix': '' };
  if (vars['request.verb'] !== 'POST') { vars['cymbal.reject'] = 'method-not-allowed'; return errorFlow(vars); }
  vars['request.content'] = typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body);
  runPolicy(MCPB, LIB, 'mcp-parse.js', vars);
  if (vars['cymbal.reject']) return errorFlow(vars);
  if (!opts.product) { vars['fault.name'] = 'InvalidApiKey'; vars['verifyapikey.VA-VerifyKey.failed'] = 'true'; return errorFlow(vars); }
  var p = PRODUCTS[opts.product];
  vars['verifyapikey.VA-VerifyKey.apiproduct.allowed_tools'] = p.allowed_tools;
  vars['verifyapikey.VA-VerifyKey.apiproduct.user_token_required'] = p.user_token_required;
  vars['verifyapikey.VA-VerifyKey.app.name'] = ('callerApp' in opts) ? opts.callerApp : APP_FOR[opts.product];
  if (opts.user || opts.badToken) {
    vars['request.header.x-user-token'] = 'eyJ.fake.jwt';
    if (opts.badToken) { vars['fault.name'] = 'InvalidToken'; vars['JWT.failed'] = 'true'; return errorFlow(vars); }
    var c = USERS[opts.user];
    Object.keys(c).forEach(function (k) { vars['jwt.JWT-Verify-UserToken.decoded.claim.' + k] = c[k]; });
  }
  runPolicy(MCPB, LIB, 'mcp-authorize.js', vars);
  if (vars['cymbal.reject']) return errorFlow(vars);
  if (vars['mcp.method'] === 'tools/call') {
    var app = opts.appId || opts.product;
    quotaUsed[app] = (quotaUsed[app] || 0) + 1;
    if (quotaUsed[app] > p.quota) { vars['fault.name'] = 'QuotaViolation'; vars['ratelimit.Q-Product-Quota.failed'] = 'true'; return errorFlow(vars); }
  }
  runPolicy(MCPB, LIB, 'mcp-respond.js', vars);
  return {
    status: Number(vars['response.status.code']),
    headers: { 'x-cymbal-decided-by': vars['response.header.x-cymbal-decided-by'], 'x-cymbal-policy': vars['response.header.x-cymbal-policy'],
      'x-cymbal-tools-listed': vars['response.header.x-cymbal-tools-listed'] },
    body: vars['response.content'] ? JSON.parse(vars['response.content']) : null,
    raw: vars['response.content']
  };
}

function rpc(id, method, params) { var m = { jsonrpc: '2.0', id: id, method: method }; if (params) m.params = params; return m; }
function call(id, name, args) { return rpc(id, 'tools/call', { name: name, arguments: args }); }

function assertDenied(r, status, policy, code) {
  assert.strictEqual(r.status, status, 'status ' + r.status + ' body ' + r.raw);
  assert.strictEqual(r.headers['x-cymbal-decided-by'], 'apigee');
  assert.strictEqual(r.headers['x-cymbal-policy'], policy);
  assert.strictEqual(r.body.jsonrpc, '2.0');
  assert.strictEqual(r.body.error.code, code === undefined ? -32001 : code);
  assert.deepStrictEqual(r.body.error.data, { decided_by: 'apigee', policy: policy });
  assert.ok(!/faultstring|VA-VerifyKey|JWT-Verify|Q-Product|steps\.|policies\./.test(r.raw), 'no policy names leak');
}

console.log('MCP server (cymbal-ge-demo-mcp-banking)');
test('initialize echoes a supported protocol version', function () {
  var r = mcpCall({ product: 'partner', body: rpc(1, 'initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 't', version: '1' } }) });
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.id, 1);
  assert.strictEqual(r.body.result.protocolVersion, '2025-03-26');
  assert.ok(r.body.result.capabilities.tools);
});
test('notifications/initialized -> 202 empty', function () {
  var r = mcpCall({ product: 'internal', body: { jsonrpc: '2.0', method: 'notifications/initialized' } });
  assert.strictEqual(r.status, 202);
  assert.strictEqual(r.body, null);
});
test('ping -> empty result', function () {
  var r = mcpCall({ product: 'internal', body: rpc('p-1', 'ping') });
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.id, 'p-1');
  assert.deepStrictEqual(r.body.result, {});
});
test('tools/list internal -> all 5 tools', function () {
  var r = mcpCall({ product: 'internal', body: rpc(2, 'tools/list') });
  assert.strictEqual(r.body.result.tools.length, 5);
  assert.strictEqual(r.headers['x-cymbal-policy'], 'allow');
});
test('tools/list partner -> filtered to get_account_summary, get_fx_rate', function () {
  var r = mcpCall({ product: 'partner', body: rpc(3, 'tools/list') });
  var names = r.body.result.tools.map(function (t) { return t.name; });
  assert.deepStrictEqual(names, ['get_account_summary', 'get_fx_rate']);
  assert.strictEqual(r.headers['x-cymbal-policy'], 'tools-filtered');
  assert.strictEqual(r.headers['x-cymbal-tools-listed'], '2');
});
test('partner tools/call outside product -> 403 tool-not-in-product', function () {
  assertDenied(mcpCall({ product: 'partner', body: call(4, 'get_account_balance', { account_id: '1234' }) }), 403, 'tool-not-in-product');
});
test('partner calling unknown tool -> 403 tool-not-in-product (name not echoed)', function () {
  var r = mcpCall({ product: 'partner', body: call(5, 'drop_tables', {}) });
  assertDenied(r, 403, 'tool-not-in-product');
  assert.ok(r.raw.indexOf('drop_tables') < 0);
});
test('internal call without x-user-token -> 401 user-token-required', function () {
  assertDenied(mcpCall({ product: 'internal', body: call(6, 'get_account_balance', { account_id: '1234' }) }), 401, 'user-token-required');
});
test('invalid user token -> 401 user-token-invalid', function () {
  assertDenied(mcpCall({ product: 'internal', badToken: true, body: call(7, 'get_account_balance', { account_id: '1234' }) }), 401, 'user-token-invalid');
});
test('S1 rm-alice balance of 1234 -> SGD 182,450.20', function () {
  var r = mcpCall({ product: 'internal', user: 'alice', body: call(8, 'get_account_balance', { account_id: '1234' }) });
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.result.isError, false);
  assert.strictEqual(r.body.result.structuredContent.balance, 182450.2);
  assert.strictEqual(r.headers['x-cymbal-policy'], 'allow');
});
test('S4 teller-bob transfer SGD 50,000 -> 403 user-transfer-limit', function () {
  var r = mcpCall({ product: 'internal', user: 'bob', body: call(9, 'transfer_funds', { from_account: '1234', to_account: '5678', amount: 50000, memo: 'test' }) });
  assertDenied(r, 403, 'user-transfer-limit');
  assert.ok(/SGD 50,000\.00/.test(r.body.error.message) && /SGD 10,000\.00/.test(r.body.error.message), r.body.error.message);
});
test('OBO: token without act claim -> 403 delegation-required', function () {
  assertDenied(mcpCall({ product: 'internal', user: 'aliceNoAct', body: call(30, 'get_account_balance', { account_id: '1234' }) }), 403, 'delegation-required');
});
test('OBO: token delegated to RM Agent, used by another app -> 403 actor-mismatch', function () {
  var r = mcpCall({ product: 'internal', user: 'alice', callerApp: 'cymbal-ge-demo-insights-app', body: call(31, 'get_account_balance', { account_id: '1234' }) });
  assertDenied(r, 403, 'actor-mismatch');
  assert.ok(/cymbal-ge-demo-agent-app/.test(r.body.error.message) && /cymbal-ge-demo-insights-app/.test(r.body.error.message), r.body.error.message);
});
test('OBO: missing caller app fails closed -> 403 actor-mismatch', function () {
  assertDenied(mcpCall({ product: 'internal', user: 'alice', callerApp: '', body: call(32, 'get_account_balance', { account_id: '1234' }) }), 403, 'actor-mismatch');
});
test('OBO: act claim parsing (JSON string, double-encoded, object, junk)', function () {
  var MCPL = require(path.join(A, MCPB, 'apiproxy', 'resources', 'jsc', 'mcp-lib.js'));
  assert.strictEqual(MCPL.actorFrom(RM_ACT), 'cymbal-ge-demo-agent-app');
  assert.strictEqual(MCPL.actorFrom(JSON.stringify(RM_ACT)), 'cymbal-ge-demo-agent-app');
  assert.strictEqual(MCPL.actorFrom({ sub: 'x' }), 'x');
  assert.strictEqual(MCPL.actorFrom('nope'), null);
  assert.strictEqual(MCPL.actorFrom('{"agent":"rm-agent"}'), null);
  assert.strictEqual(MCPL.actorFrom(null), null);
});
test('rm-alice transfer SGD 50,000 -> accepted (simulated)', function () {
  var r = mcpCall({ product: 'internal', user: 'alice', body: call(10, 'transfer_funds', { from_account: '1234', to_account: '5678', amount: 50000 }) });
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.result.structuredContent.status, 'accepted');
  assert.strictEqual(r.body.result.structuredContent.initiated_by, 'rm-alice');
});
test('teller-bob transfer at exactly the limit is allowed', function () {
  var r = mcpCall({ product: 'internal', user: 'bob', body: call(11, 'transfer_funds', { from_account: '1234', to_account: '5678', amount: 10000 }) });
  assert.strictEqual(r.status, 200);
});
test('transfer with invalid amount -> 400 invalid-params (-32602)', function () {
  assertDenied(mcpCall({ product: 'internal', user: 'alice', body: call(12, 'transfer_funds', { from_account: '1234', to_account: '5678', amount: -5 }) }), 400, 'invalid-params', -32602);
});
test('list_transactions limit 50 -> 50 deterministic rows', function () {
  var a = mcpCall({ product: 'internal', user: 'alice', body: call(13, 'list_transactions', { account_id: '1234', limit: 50 }) });
  var b = mcpCall({ product: 'internal', user: 'alice', body: call(14, 'list_transactions', { account_id: '1234', limit: 50 }) });
  assert.strictEqual(a.body.result.structuredContent.count, 50);
  assert.deepStrictEqual(a.body.result.structuredContent, b.body.result.structuredContent);
});
test('unknown account -> tool result isError (HTTP 200)', function () {
  var r = mcpCall({ product: 'internal', user: 'alice', body: call(15, 'get_account_balance', { account_id: '9999' }) });
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.result.isError, true);
});
test('partner get_fx_rate SGD/USD', function () {
  var r = mcpCall({ product: 'partner', appId: 'fx', body: call(16, 'get_fx_rate', { base: 'sgd', quote: 'USD' }) });
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.result.structuredContent.pair, 'SGD/USD');
});
test('S7 partner get_account_summary x6 -> 5 allowed then 429 product-quota', function () {
  var statuses = [];
  var last;
  for (var i = 0; i < 6; i++) {
    last = mcpCall({ product: 'partner', appId: 'finpal-s7', body: call(100 + i, 'get_account_summary', { account_id: '1234' }) });
    statuses.push(last.status);
  }
  assert.deepStrictEqual(statuses, [200, 200, 200, 200, 200, 429]);
  assertDenied(last, 429, 'product-quota');
  assert.strictEqual(last.body.id, 105);
});
test('summary is masked (no holder name, banded balance)', function () {
  var r = mcpCall({ product: 'partner', appId: 'mask', body: call(17, 'get_account_summary', { account_id: '1234' }) });
  var s = r.body.result.structuredContent;
  assert.strictEqual(s.account, '****1234');
  assert.ok(!('holder' in s) && !('balance' in s));
  assert.ok(r.raw.indexOf('Tan Wei Ming') < 0);
});
test('missing x-api-key -> 401 invalid-api-key', function () {
  assertDenied(mcpCall({ product: null, body: rpc(18, 'tools/list') }), 401, 'invalid-api-key');
});
test('malformed JSON -> 400 parse-error, id null', function () {
  var r = mcpCall({ product: 'internal', body: '{"jsonrpc":' });
  assertDenied(r, 400, 'parse-error', -32700);
  assert.strictEqual(r.body.id, null);
});
test('batch array -> 400 invalid-request', function () {
  assertDenied(mcpCall({ product: 'internal', body: [rpc(1, 'ping')] }), 400, 'invalid-request', -32600);
});
test('unsupported method -> 400 method-not-found', function () {
  assertDenied(mcpCall({ product: 'internal', body: rpc(19, 'resources/list') }), 400, 'method-not-found', -32601);
});
test('GET -> 405 method-not-allowed', function () {
  assertDenied(mcpCall({ verb: 'GET' }), 405, 'method-not-allowed', -32600);
});
test('object id is rejected and never echoed', function () {
  var r = mcpCall({ product: 'internal', body: { jsonrpc: '2.0', id: { x: 1 }, method: 'ping' } });
  assertDenied(r, 400, 'invalid-request', -32600);
  assert.strictEqual(r.body.id, null);
});
test('unknown native fault -> 500 internal-error with JSON-RPC shape', function () {
  var r = errorFlow({ 'fault.name': 'SomethingElse', 'mcp.id_json': '"abc"' });
  assertDenied(r, 500, 'internal-error', -32603);
  assert.strictEqual(r.body.id, 'abc');
});

// ============================================================================ LLM
var LLMB = 'cymbal-ge-demo-llm';
var LLM = require(path.join(A, LLMB, 'apiproxy', 'resources', 'jsc', 'llm-lib.js'));
var CFG = { alias: 'cymbal-auto', defaultModel: 'gemini-3.5-flash', routedModel: 'gemini-3.5-flash-lite', threshold: 6000,
  allowedModels: 'gemini-3.5-flash gemini-3.5-flash-lite' };
var PATH = function (model, verb, loc) {
  return '/v1/projects/any-project/locations/' + (loc || 'global') + '/publishers/google/models/' + model + ':' + (verb || 'generateContent');
};
var body = function (n) { return JSON.stringify({ contents: [{ role: 'user', parts: [{ text: new Array(n + 1).join('x') }] }] }); };

console.log('LLM gateway (cymbal-ge-demo-llm)');
test('cymbal-auto short prompt -> gemini-3.5-flash', function () {
  var r = LLM.route({ pathsuffix: PATH('cymbal-auto'), bodyText: body(100), config: CFG });
  assert.strictEqual(r.model, 'gemini-3.5-flash');
  assert.strictEqual(r.route, 'auto-default');
});
test('cymbal-auto >6000 chars -> gemini-3.5-flash-lite', function () {
  var r = LLM.route({ pathsuffix: PATH('cymbal-auto'), bodyText: body(6001), config: CFG });
  assert.strictEqual(r.model, 'gemini-3.5-flash-lite');
  assert.strictEqual(r.route, 'auto-long-prompt');
});
test('exactly 6000 chars stays on flash; systemInstruction counted', function () {
  assert.strictEqual(LLM.route({ pathsuffix: PATH('cymbal-auto'), bodyText: body(6000), config: CFG }).model, 'gemini-3.5-flash');
  var b = JSON.parse(body(5990)); b.systemInstruction = { parts: [{ text: '0123456789A' }] };
  assert.strictEqual(LLM.route({ pathsuffix: PATH('cymbal-auto'), bodyText: JSON.stringify(b), config: CFG }).model, 'gemini-3.5-flash-lite');
});
test('explicit allowlisted model passes', function () {
  assert.strictEqual(LLM.route({ pathsuffix: PATH('gemini-3.5-flash-lite'), bodyText: body(10), config: CFG }).route, 'explicit');
});
test('model outside allowlist -> model-not-allowed', function () {
  assert.strictEqual(LLM.route({ pathsuffix: PATH('gemini-2.5-pro'), bodyText: body(10), config: CFG }).reason, 'model-not-allowed');
});
test(':streamGenerateContent and alt=sse -> streaming-not-supported', function () {
  assert.strictEqual(LLM.route({ pathsuffix: PATH('cymbal-auto', 'streamGenerateContent'), bodyText: body(10), config: CFG }).reason, 'streaming-not-supported');
  assert.strictEqual(LLM.route({ pathsuffix: PATH('cymbal-auto'), query: 'alt=sse', bodyText: body(10), config: CFG }).reason, 'streaming-not-supported');
});
test('non-global location / bad path / bad body', function () {
  assert.strictEqual(LLM.route({ pathsuffix: PATH('cymbal-auto', null, 'us-central1'), bodyText: body(1), config: CFG }).reason, 'location-not-allowed');
  assert.strictEqual(LLM.route({ pathsuffix: '/v1/models', bodyText: body(1), config: CFG }).reason, 'unknown-path');
  assert.strictEqual(LLM.route({ pathsuffix: PATH('cymbal-auto', 'countTokens'), bodyText: body(1), config: CFG }).reason, 'unknown-path');
  assert.strictEqual(LLM.route({ pathsuffix: PATH('cymbal-auto'), bodyText: '{}', config: CFG }).reason, 'invalid-request');
  assert.strictEqual(LLM.route({ pathsuffix: PATH('cymbal-auto'), bodyText: 'nope', config: CFG }).reason, 'invalid-request');
});
test('usage: valid totalTokenCount (thinking model without candidatesTokenCount)', function () {
  var u = LLM.usage(JSON.stringify({ usageMetadata: { promptTokenCount: 3, totalTokenCount: 15, thoughtsTokenCount: 12 } }));
  assert.deepStrictEqual(u, { valid: true, total: 15, prompt: 3, output: 0, thinking: 12 });
  assert.strictEqual(LLM.usage('{}').valid, false);
  assert.strictEqual(LLM.usage(JSON.stringify({ usageMetadata: { totalTokenCount: -1 } })).valid, false);
});
test('error mapping: budget 429 vs upstream 429 -> 503, key 401, upstream 400', function () {
  assert.strictEqual(LLM.faultReason(null, 'LLMTokenQuotaViolation', {}), 'llm-token-budget');
  assert.strictEqual(LLM.faultReason(null, 'ErrorResponseCode', { inTarget: true, upstreamStatus: 429 }), 'upstream-rate-limited');
  assert.strictEqual(LLM.faultReason(null, 'ErrorResponseCode', { inTarget: true, upstreamStatus: 400 }), 'upstream-rejected');
  assert.strictEqual(LLM.faultReason(null, 'ErrorResponseCode', { inTarget: true, upstreamStatus: 500 }), 'upstream-error');
  assert.strictEqual(LLM.faultReason(null, 'FailedToResolveAPIKey', {}), 'invalid-api-key');
  var e = LLM.buildError('llm-token-budget');
  assert.strictEqual(e.status, 429);
  assert.deepStrictEqual(JSON.parse(e.body).error.policy, 'llm-token-budget');
  assert.strictEqual(JSON.parse(e.body).error.decided_by, 'apigee');
});
test('glue: JS-Llm-Route sets ai.upstream_model / fails closed without product budget', function () {
  var props = { 'propertyset.llm.alias': 'cymbal-auto', 'propertyset.llm.default_model': 'gemini-3.5-flash',
    'propertyset.llm.routed_model': 'gemini-3.5-flash-lite', 'propertyset.llm.auto_threshold_chars': '6000',
    'propertyset.llm.allowed_models': 'gemini-3.5-flash gemini-3.5-flash-lite' };
  var v = Object.assign({ 'proxy.pathsuffix': PATH('cymbal-auto'), 'request.content': body(7000),
    'verifyapikey.VA-VerifyKey.apiproduct.developer.llmQuota.limit': '20000' }, props);
  runPolicy(LLMB, ['llm-lib.js'], 'llm-route.js', v);
  assert.strictEqual(v['ai.upstream_model'], 'gemini-3.5-flash-lite');
  assert.strictEqual(v['ai.policy'], 'model-routing');
  var v2 = Object.assign({ 'proxy.pathsuffix': PATH('cymbal-auto'), 'request.content': body(10) }, props);
  runPolicy(LLMB, ['llm-lib.js'], 'llm-route.js', v2);
  assert.strictEqual(v2['cymbal.reject'], 'llm-budget-not-configured');
});
test('glue: JS-Build-Error in target fault with upstream 429', function () {
  var v = { 'fault.name': 'ErrorResponseCode', 'cymbal.in_target': 'true', 'response.status.code': '429' };
  runPolicy(LLMB, ['llm-lib.js'], 'build-error.js', v);
  assert.strictEqual(v['cymbal.err_status'], '503');
  assert.strictEqual(v['cymbal.err_policy'], 'upstream-rate-limited');
});

// ============================================================================ ext-proc
var EXB = 'cymbal-ge-demo-extproc';
var EX = require(path.join(A, EXB, 'apiproxy', 'resources', 'jsc', 'extproc-lib.js'));
var CB = 'cymbal-ge-demo-credit-bureau-abc123-as.a.run.app, cymbal-ge-demo-credit-bureau-YOUR_PROJECT_NUMBER.asia-southeast1.run.app';
var IDH = 'x-agent-identity,x-forwarded-client-cert';
console.log('Ext-proc (cymbal-ge-demo-extproc)');
test('other hosts are not governed', function () {
  var c = EX.classify({ host: 'YOUR_APIGEE_HOST', verb: 'POST', bodyText: '{"method":"tools/call"}', cbHosts: CB, identityHeaders: IDH });
  assert.strictEqual(c.governed, false);
  assert.strictEqual(c.count, false);
});
test('credit bureau tools/call is counted; host port/case ignored; fallback key per host', function () {
  var c = EX.classify({ host: 'Cymbal-GE-Demo-Credit-Bureau-YOUR_PROJECT_NUMBER.asia-southeast1.run.app:443', verb: 'POST',
    bodyText: '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_credit_report"}}', headers: {}, cbHosts: CB, identityHeaders: IDH });
  assert.strictEqual(c.governed, true);
  assert.strictEqual(c.count, true);
  assert.strictEqual(c.quotaKey, 'host:cymbal-ge-demo-credit-bureau-YOUR_PROJECT_NUMBER.asia-southeast1.run.app');
  assert.strictEqual(c.keySource, 'host');
});
test('MCP handshake (initialize, notifications, tools/list) is not counted', function () {
  ['initialize', 'notifications/initialized', 'tools/list'].forEach(function (m) {
    var c = EX.classify({ host: 'cymbal-ge-demo-credit-bureau-abc123-as.a.run.app', verb: 'POST', bodyText: JSON.stringify({ jsonrpc: '2.0', method: m }), cbHosts: CB, identityHeaders: IDH });
    assert.strictEqual(c.count, false, m);
  });
});
test('no body forwarded -> every POST counted; GET never', function () {
  assert.strictEqual(EX.classify({ host: 'cymbal-ge-demo-credit-bureau-abc123-as.a.run.app', verb: 'POST', bodyText: null, cbHosts: CB, identityHeaders: IDH }).count, true);
  assert.strictEqual(EX.classify({ host: 'cymbal-ge-demo-credit-bureau-abc123-as.a.run.app', verb: 'GET', bodyText: null, cbHosts: CB, identityHeaders: IDH }).count, false);
});
test('identity header and XFCC SPIFFE URI become the quota key', function () {
  var h = 'cymbal-ge-demo-credit-bureau-abc123-as.a.run.app';
  var a = EX.classify({ host: h, verb: 'POST', headers: { 'x-agent-identity': 'agents/rm agent' }, cbHosts: CB, identityHeaders: IDH });
  assert.strictEqual(a.quotaKey, 'id:agents/rm_agent');
  var b = EX.classify({ host: h, verb: 'POST', headers: { 'x-forwarded-client-cert': 'Hash=abc;URI=spiffe://YOUR_PROJECT_ID.svc.id.goog/ns/agents/sa/rm;By=x' }, cbHosts: CB, identityHeaders: IDH });
  assert.strictEqual(b.quotaKey, 'id:spiffe://YOUR_PROJECT_ID.svc.id.goog/ns/agents/sa/rm');
  assert.strictEqual(b.keySource, 'x-forwarded-client-cert');
});
test('placeholder host list governs nothing', function () {
  assert.strictEqual(EX.classify({ host: 'cymbal-ge-demo-credit-bureau-abc123-as.a.run.app', verb: 'POST', cbHosts: '__CREDIT_BUREAU_HOSTS__', identityHeaders: IDH }).governed, false);
});
test('glue: classify script never throws, even with no properties', function () {
  var v = { 'request.verb': 'POST', 'request.header.host': 'example.com' };
  runPolicy(EXB, ['extproc-lib.js'], 'extproc-classify.js', v);
  assert.strictEqual(v['cymbal.cb_governed'], 'false');
  var v2 = { 'request.verb': 'POST', 'request.header.host': 'cymbal-ge-demo-credit-bureau-abc123-as.a.run.app',
    'request.content': '{"jsonrpc":"2.0","id":3,"method":"tools/call"}', 'propertyset.extproc.credit_bureau_hosts': CB,
    'propertyset.extproc.identity_headers': IDH };
  runPolicy(EXB, ['extproc-lib.js'], 'extproc-classify.js', v2);
  assert.strictEqual(v2['cymbal.cb_count'], 'true');
  assert.strictEqual(v2['cymbal.quota_key_source'], 'host');
});

// ============================================================================ credit bureau (S5)
var CBB = 'cymbal-ge-demo-credit-bureau';
var CBL = require(path.join(A, CBB, 'apiproxy', 'resources', 'jsc', 'bureau-lib.js'));
var cbQuota = {};
/** Mirrors the bureau ProxyEndpoint: classify -> Q-Credit-Bureau (paid only, 3 per window per app) -> target. */
function bureauCall(opts) {
  var vars = { 'request.content': typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body) };
  function err() {
    runPolicy(CBB, ['bureau-lib.js'], 'build-error.js', vars);
    return { status: Number(vars['cymbal.err_status']), policy: vars['cymbal.err_policy'], body: JSON.parse(vars['cymbal.err_body']), raw: vars['cymbal.err_body'] };
  }
  if (!opts.key) { vars['fault.name'] = 'FailedToResolveAPIKey'; return err(); }
  runPolicy(CBB, ['bureau-lib.js'], 'bureau-classify.js', vars);
  if (vars['cymbal.reject']) return err();
  if (vars['bureau.paid'] === 'true') {
    cbQuota[opts.key] = (cbQuota[opts.key] || 0) + 1;
    if (cbQuota[opts.key] > 3) { vars['fault.name'] = 'QuotaViolation'; vars['ratelimit.Q-Credit-Bureau.failed'] = 'true'; return err(); }
  }
  if (opts.upstream5xx) { vars['fault.name'] = 'ErrorResponseCode'; vars['cymbal.in_target'] = 'true'; return err(); }
  return { status: 200, policy: 'allow', forwardedBody: vars['request.content'] };
}
console.log('Credit bureau proxy (cymbal-ge-demo-credit-bureau)');
test('classify: only tools/call is paid', function () {
  assert.strictEqual(CBL.classify(JSON.stringify(call(1, 'get_credit_report', { customer_id: 'CUST-101' }))).paid, true);
  ['initialize', 'tools/list', 'ping'].forEach(function (m) { assert.strictEqual(CBL.classify(JSON.stringify(rpc(2, m))).paid, false, m); });
  assert.strictEqual(CBL.classify('{"jsonrpc":"2.0","method":"notifications/initialized"}').paid, false);
});
test('classify: malformed / batch / bad id rejected', function () {
  assert.strictEqual(CBL.classify('{"jsonrpc":').reason, 'parse-error');
  assert.strictEqual(CBL.classify('[{"jsonrpc":"2.0","id":1,"method":"tools/call"}]').reason, 'invalid-request');
  assert.strictEqual(CBL.classify('{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}').reason, 'invalid-request');
  assert.strictEqual(CBL.classify('{"id":1,"method":"ping"}').reason, 'invalid-request');
});
test('S5: 3 lookups with handshake interleaved, 4th -> 429 credit-bureau-quota, handshake still free', function () {
  var k = 'agent-s5';
  var seq = [
    [call(1, 'get_credit_report', { customer_id: 'CUST-101' }), 200], [rpc(2, 'tools/list'), 200],
    [call(3, 'get_credit_report', { customer_id: 'CUST-102' }), 200], [rpc(4, 'initialize', {}), 200],
    [{ jsonrpc: '2.0', method: 'notifications/initialized' }, 200],
    [call(5, 'get_credit_report', { customer_id: 'CUST-103' }), 200], [call(6, 'get_credit_report', { customer_id: 'CUST-104' }), 429],
    [rpc(7, 'tools/list'), 200]
  ];
  var last;
  seq.forEach(function (s, i) { last = bureauCall({ key: k, body: s[0] }); assert.strictEqual(last.status, s[1], 'step ' + i); if (s[1] === 429) {
    assert.strictEqual(last.policy, 'credit-bureau-quota');
    assert.deepStrictEqual(last.body.error.data, { decided_by: 'apigee', policy: 'credit-bureau-quota' });
    assert.strictEqual(last.body.error.code, -32001);
    assert.strictEqual(last.body.id, 6);
  } });
});
test('quota is per app (another app is unaffected)', function () {
  assert.strictEqual(bureauCall({ key: 'other-app', body: call(9, 'get_credit_report', { customer_id: 'CUST-101' }) }).status, 200);
});
test('request body is forwarded byte-for-byte (classify never rewrites it)', function () {
  var raw = '{"jsonrpc":"2.0","id":"x-1","method":"tools/call","params":{"name":"get_credit_report","arguments":{"customer_id":"CUST-666"}}}';
  assert.strictEqual(bureauCall({ key: 'raw-app', body: raw }).forwardedBody, raw);
});
test('errors: missing key 401, bureau 5xx -> 502 upstream-error, unknown -> 500; no leaks', function () {
  var a = bureauCall({ key: null, body: rpc(1, 'tools/list') });
  assert.strictEqual(a.status, 401); assert.strictEqual(a.policy, 'invalid-api-key');
  var b = bureauCall({ key: 'up-app', upstream5xx: true, body: call(2, 'get_credit_report', { customer_id: 'CUST-101' }) });
  assert.strictEqual(b.status, 502); assert.strictEqual(b.policy, 'upstream-error'); assert.strictEqual(b.body.id, 2);
  assert.strictEqual(CBL.faultReason(null, 'Weird', {}), 'internal-error');
  [a, b].forEach(function (r) { assert.ok(!/faultstring|VA-VerifyKey|Q-Credit|steps\./.test(r.raw)); });
});

// ============================================================================ token
var TKB = 'cymbal-ge-demo-token';
var TK = require(path.join(A, TKB, 'apiproxy', 'resources', 'jsc', 'resolve-user.js'));
var TE = require(path.join(A, TKB, 'apiproxy', 'resources', 'jsc', 'build-error.js'));
console.log('Token facade (cymbal-ge-demo-token)');
test('rm-alice / teller-bob claims per DESIGN.md', function () {
  var a = TK.resolveUser('{"user":"rm-alice","actor":"rm-agent"}');
  assert.deepStrictEqual([a.role, a.scope, a.transfer_limit], ['relationship_manager', 'accounts:read payments:write', 100000]);
  var b = TK.resolveUser('{"user":"teller-bob","actor":"rm-agent"}');
  assert.deepStrictEqual([b.role, b.scope, b.transfer_limit], ['teller', 'accounts:read payments:write', 10000]);
});
test('OBO: act names the agent app (rm-agent / insights-agent)', function () {
  assert.deepStrictEqual(TK.resolveUser('{"user":"rm-alice","actor":"rm-agent"}').act,
    { sub: 'cymbal-ge-demo-agent-app', agent: 'rm-agent', name: 'RM Agent' });
  assert.strictEqual(TK.resolveUser('{"user":"teller-bob","actor":"insights-agent"}').act.sub, 'cymbal-ge-demo-insights-app');
});
test('OBO: missing / unknown / prototype actor rejected', function () {
  assert.strictEqual(TK.resolveUser('{"user":"rm-alice"}').reject, 'unknown-actor');
  assert.strictEqual(TK.resolveUser('{"user":"rm-alice","actor":"evil-agent"}').reject, 'unknown-actor');
  assert.strictEqual(TK.resolveUser('{"user":"rm-alice","actor":"__proto__"}').reject, 'unknown-actor');
  assert.strictEqual(TK.resolveUser('{"user":"rm-alice","actor":7}').reject, 'unknown-actor');
});
test('unknown user / bad JSON / prototype keys rejected', function () {
  assert.strictEqual(TK.resolveUser('{"user":"mallory"}').reject, 'unknown-user');
  assert.strictEqual(TK.resolveUser('{"user":"__proto__"}').reject, 'unknown-user');
  assert.strictEqual(TK.resolveUser('{"user":"toString"}').reject, 'unknown-user');
  assert.strictEqual(TK.resolveUser('nope').reject, 'invalid-request');
  assert.strictEqual(TK.resolveUser(null).reject, 'invalid-request');
});
test('glue: resolve-user sets claim variables', function () {
  var v = { 'request.content': '{"user":"teller-bob","actor":"rm-agent"}' };
  runPolicy(TKB, [], 'resolve-user.js', v);
  assert.strictEqual(v['cymbal.transfer_limit'], '10000');
  assert.strictEqual(v['cymbal.sub'], 'teller-bob');
  assert.deepStrictEqual(JSON.parse(v['cymbal.act_json']), { sub: 'cymbal-ge-demo-agent-app', agent: 'rm-agent', name: 'RM Agent' });
  assert.strictEqual(v['cymbal.act_client'], 'cymbal-ge-demo-agent-app');
});
test('error mapping: key fault 401, reject reasons, default 500', function () {
  assert.strictEqual(TE.reasonFor(null, 'InvalidApiKeyForGivenResource', {}), 'invalid-api-key');
  assert.strictEqual(TE.reasonFor('unknown-user', null, {}), 'unknown-user');
  assert.strictEqual(TE.reasonFor(null, 'Weird', {}), 'internal-error');
  var e = JSON.parse(TE.buildError('invalid-api-key').body);
  assert.strictEqual(e.error.decided_by, 'apigee');
  assert.strictEqual(e.error.code, 401);
});

console.log('\n' + passed + ' passed, ' + failed + ' failed');
process.exit(failed ? 1 : 0);
