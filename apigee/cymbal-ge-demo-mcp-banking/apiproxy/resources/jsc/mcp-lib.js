/*
 * mcp-lib.js  (cymbal-ge-demo-mcp-banking)
 * Pure functions for the Apigee-hosted MCP server (Streamable HTTP, JSON responses, no SSE).
 * Included with <IncludeURL> by JS-Mcp-Parse, JS-Mcp-Authorize, JS-Mcp-Respond and JS-Build-Error,
 * and loaded by tests/mcp-lib.test.js under node. No Apigee objects are touched here.
 *
 * Mock core-banking data only (DESIGN.md): accounts 1234 / 5678 / 9012, deterministic transactions,
 * FX table. Transfers are simulated and never persisted.
 * ES5 only (Apigee JavaScript runtime).
 */
var MCP = (function () {
  'use strict';

  var SUPPORTED_PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05'];
  var DEFAULT_PROTOCOL = '2025-06-18';
  var SERVER_INFO = { name: 'cymbal-ge-demo-mcp-banking', title: 'Cymbal Bank Core Banking (via Apigee)', version: '1.0.0' };
  var MAX_BODY = 65536;

  // ---------------------------------------------------------------- reasons (HTTP status, JSON-RPC code, message)
  // Policy decisions use -32001 (DESIGN.md); protocol errors use the standard JSON-RPC codes.
  var REASONS = {
    'parse-error': [400, -32700, 'Parse error: body must be a single JSON-RPC 2.0 object.'],
    'invalid-request': [400, -32600, 'Invalid JSON-RPC 2.0 request.'],
    'method-not-allowed': [405, -32600, 'Only POST is supported (this server does not offer an SSE stream).'],
    'unknown-path': [404, -32600, 'Unknown path. POST JSON-RPC to /cymbal-ge-demo/mcp/banking.'],
    'method-not-found': [400, -32601, 'Method not supported by this MCP server.'],
    'invalid-params': [400, -32602, 'Invalid tool arguments.'],
    'unknown-tool': [400, -32602, 'Unknown tool.'],
    'invalid-api-key': [401, -32001, 'A valid x-api-key is required.'],
    'user-token-required': [401, -32001, 'This API product requires the end-user token in x-user-token.'],
    'user-token-invalid': [401, -32001, 'The end-user token in x-user-token is invalid or expired.'],
    'tool-not-in-product': [403, -32001, 'This tool is not included in your API product.'],
    'user-scope-missing': [403, -32001, 'The end user is missing the scope required for this tool.'],
    'user-transfer-limit': [403, -32001, 'The transfer amount exceeds the end user\'s transfer limit.'],
    'delegation-required': [403, -32001, 'The end-user token is not a delegated token (no act claim naming the calling agent).'],
    'actor-mismatch': [403, -32001, 'The end-user token was delegated to a different agent than the one calling.'],
    'product-quota': [429, -32001, 'API product quota exceeded. Retry after the quota window resets.'],
    'rate-limited': [429, -32001, 'Too many requests; slow down.'],
    'internal-error': [500, -32603, 'Internal error.']
  };

  // ---------------------------------------------------------------- mock data
  var ACCOUNTS = {
    '1234': { holder: 'Tan Wei Ming', initials: 'T.W.M.', product: 'Premier Current Account', currency: 'SGD',
      balance: 182450.20, status: 'active', branch: 'Marina Bay Financial Centre', relationship_manager: 'rm-alice' },
    '5678': { holder: 'Priya Nair', initials: 'P.N.', product: 'Everyday Savings Account', currency: 'SGD',
      balance: 45210.75, status: 'active', branch: 'Raffles Place', relationship_manager: 'rm-alice' },
    '9012': { holder: 'Lim Hardware Trading Pte Ltd', initials: 'L.H.T.', product: 'Business Current Account', currency: 'SGD',
      balance: 9876.50, status: 'active', branch: 'Jurong East', relationship_manager: 'rm-carol' }
  };

  var MERCHANTS = [
    ['NTUC FairPrice', 'groceries', -1], ['Grab', 'transport', -1], ['Singapore Power', 'utilities', -1],
    ['Salary - Cymbal Logistics', 'income', 1], ['Shopee', 'shopping', -1], ['Changi Airport DFS', 'travel', -1],
    ['SP Group refund', 'refund', 1], ['Starbucks Raffles', 'dining', -1], ['IRAS', 'tax', -1],
    ['Interest credit', 'interest', 1], ['Lazada', 'shopping', -1], ['Singtel', 'utilities', -1],
    ['Dividend - STI ETF', 'investment', 1], ['Din Tai Fung', 'dining', -1], ['FairPrice Xtra', 'groceries', -1]
  ];

  // Deterministic LCG so every run (and every runtime node) returns identical transactions.
  function rng(seed) {
    var s = seed >>> 0;
    return function () {
      s = (Math.imul ? Math.imul(s, 1664525) : (s * 1664525) | 0) + 1013904223;
      s = s >>> 0;
      return s / 4294967296;
    };
  }

  function round2(n) {
    return Math.round(n * 100) / 100;
  }

  var TXN_CACHE = {};
  function transactions(accountId) {
    if (TXN_CACHE[accountId]) return TXN_CACHE[accountId];
    var r = rng(parseInt(accountId, 10) * 7919);
    var out = [];
    var day = Date.UTC(2026, 10, 16); // 2026-11-16, newest first
    for (var i = 0; i < 50; i++) {
      var m = MERCHANTS[Math.floor(r() * MERCHANTS.length)];
      var magnitude = m[2] > 0 ? 500 + r() * 6000 : 5 + r() * 850;
      day -= Math.floor(r() * 2) * 86400000;
      out.push({
        id: 'TXN-' + accountId + '-' + (1000 + i),
        date: new Date(day).toISOString().slice(0, 10),
        description: m[0],
        category: m[1],
        amount: round2(m[2] * magnitude),
        currency: 'SGD'
      });
    }
    TXN_CACHE[accountId] = out;
    return out;
  }

  // SGD per 1 unit of currency (mock mid-market rates).
  var SGD_PER = { SGD: 1, USD: 1.3492, EUR: 1.4592, GBP: 1.7121, MYR: 0.2880, JPY: 0.008712,
    AUD: 0.8835, CNY: 0.1862, HKD: 0.1733, INR: 0.01601 };

  // ---------------------------------------------------------------- tool catalog
  var ACCOUNT_ID_SCHEMA = { type: 'string', pattern: '^[0-9]{4,12}$', description: 'Cymbal Bank account number, e.g. 1234.' };

  var TOOLS = [
    {
      name: 'get_account_balance',
      title: 'Get account balance',
      description: 'Current and available balance of a Cymbal Bank account (internal, full detail).',
      inputSchema: { type: 'object', properties: { account_id: ACCOUNT_ID_SCHEMA }, required: ['account_id'], additionalProperties: false },
      annotations: { readOnlyHint: true, openWorldHint: false }
    },
    {
      name: 'list_transactions',
      title: 'List recent transactions',
      description: 'Most recent transactions of an account, newest first (max 50).',
      inputSchema: {
        type: 'object',
        properties: {
          account_id: ACCOUNT_ID_SCHEMA,
          limit: { type: 'integer', minimum: 1, maximum: 50, default: 10, description: 'Number of transactions (1-50).' }
        },
        required: ['account_id'],
        additionalProperties: false
      },
      annotations: { readOnlyHint: true, openWorldHint: false }
    },
    {
      name: 'transfer_funds',
      title: 'Transfer funds',
      description: 'Transfer SGD between Cymbal Bank accounts. Requires the end user\'s payments:write scope and an amount within the user\'s transfer limit.',
      inputSchema: {
        type: 'object',
        properties: {
          from_account: ACCOUNT_ID_SCHEMA,
          to_account: ACCOUNT_ID_SCHEMA,
          amount: { type: 'number', exclusiveMinimum: 0, description: 'Amount in SGD.' },
          memo: { type: 'string', maxLength: 140 }
        },
        required: ['from_account', 'to_account', 'amount'],
        additionalProperties: false
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
    },
    {
      name: 'get_account_summary',
      title: 'Get masked account summary',
      description: 'Partner-safe, masked account summary (no holder name, banded balance).',
      inputSchema: { type: 'object', properties: { account_id: ACCOUNT_ID_SCHEMA }, required: ['account_id'], additionalProperties: false },
      annotations: { readOnlyHint: true, openWorldHint: false }
    },
    {
      name: 'get_fx_rate',
      title: 'Get FX rate',
      description: 'Indicative mid-market FX rate between two ISO 4217 currencies.',
      inputSchema: {
        type: 'object',
        properties: {
          base: { type: 'string', pattern: '^[A-Za-z]{3}$', description: 'Base currency, e.g. SGD.' },
          quote: { type: 'string', pattern: '^[A-Za-z]{3}$', description: 'Quote currency, e.g. USD.' }
        },
        required: ['base', 'quote'],
        additionalProperties: false
      },
      annotations: { readOnlyHint: true, openWorldHint: false }
    }
  ];

  var TOOL_NAMES = [];
  for (var t = 0; t < TOOLS.length; t++) TOOL_NAMES.push(TOOLS[t].name);

  // Tools that act on behalf of the end user (need the user JWT when one is required or present).
  var USER_SCOPES = {
    get_account_balance: 'accounts:read',
    list_transactions: 'accounts:read',
    transfer_funds: 'payments:write'
  };

  // ---------------------------------------------------------------- helpers
  function has(obj, key) {
    return obj !== null && typeof obj === 'object' && Object.prototype.hasOwnProperty.call(obj, key);
  }

  function isValidId(id) {
    return id === null || typeof id === 'string' || (typeof id === 'number' && isFinite(id));
  }

  function safeIdJson(idJson) {
    if (idJson === null || idJson === undefined || idJson === '') return 'null';
    try {
      var v = JSON.parse(String(idJson));
      return isValidId(v) ? JSON.stringify(v) : 'null';
    } catch (e) {
      return 'null';
    }
  }

  function parseAllowedTools(attr) {
    if (attr === null || attr === undefined) return [];
    var parts = String(attr).split(/[\s,]+/);
    var out = [];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] === '*') return TOOL_NAMES.slice();
      if (parts[i] && TOOL_NAMES.indexOf(parts[i]) >= 0 && out.indexOf(parts[i]) < 0) out.push(parts[i]);
    }
    return out;
  }

  function claim(v) {
    if (v === null || v === undefined) return null;
    var s = String(v);
    if (s.length >= 2 && s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') {
      try { return JSON.parse(s); } catch (e) { return s; }
    }
    return s;
  }

  /** RFC 8693 actor claim: VerifyJWT exposes a map claim as a JSON string (an object in tests). Returns act.sub or null. */
  function actorFrom(v) {
    if (v === null || v === undefined || v === '') return null;
    var obj = v;
    if (typeof v === 'string') {
      try { obj = JSON.parse(v); } catch (e) { return null; }
      if (typeof obj === 'string') { try { obj = JSON.parse(obj); } catch (e2) { return null; } }
    }
    if (obj === null || typeof obj !== 'object') return null;
    return (typeof obj.sub === 'string' && obj.sub) ? obj.sub : null;
  }

  /** Builds the verified-user view from VerifyJWT claim variables (null when no token was presented). */
  function userFromClaims(present, c) {
    if (!present) return null;
    var limit = Number(claim(c.transfer_limit));
    var scope = claim(c.scope);
    return {
      sub: claim(c.sub),
      role: claim(c.role),
      scopes: scope ? String(scope).split(/\s+/) : [],
      transferLimit: isFinite(limit) ? limit : 0,
      hasExp: claim(c.exp) !== null && claim(c.exp) !== '',
      actor: actorFrom(c.act)
    };
  }

  function fmtSgd(n) {
    var parts = round2(n).toFixed(2).split('.');
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return 'SGD ' + parts.join('.');
  }

  function accountId(v) {
    if (typeof v === 'number' && isFinite(v) && v >= 0 && Math.floor(v) === v) v = String(v);
    return (typeof v === 'string' && /^[0-9]{4,12}$/.test(v)) ? v : null;
  }

  // ---------------------------------------------------------------- 1. parse
  /**
   * Validates one JSON-RPC 2.0 message. Returns
   * {ok:true, kind:'request'|'notification'|'response', id, idJson, method, params, tool, args}
   * or {ok:false, reason, idJson}.
   */
  function parse(bodyText) {
    if (bodyText === null || bodyText === undefined || bodyText === '') return { ok: false, reason: 'parse-error', idJson: 'null' };
    var text = String(bodyText);
    if (text.length > MAX_BODY) return { ok: false, reason: 'invalid-request', idJson: 'null' };
    var msg;
    try { msg = JSON.parse(text); } catch (e) { return { ok: false, reason: 'parse-error', idJson: 'null' }; }
    if (msg === null || typeof msg !== 'object' || msg instanceof Array) return { ok: false, reason: 'invalid-request', idJson: 'null' };
    var hasId = has(msg, 'id');
    var idJson = hasId && isValidId(msg.id) ? JSON.stringify(msg.id) : 'null';
    if (msg.jsonrpc !== '2.0') return { ok: false, reason: 'invalid-request', idJson: idJson };
    if (hasId && !isValidId(msg.id)) return { ok: false, reason: 'invalid-request', idJson: 'null' };
    if (!has(msg, 'method')) {
      if (hasId && (has(msg, 'result') || has(msg, 'error'))) return { ok: true, kind: 'response', idJson: idJson, method: '' };
      return { ok: false, reason: 'invalid-request', idJson: idJson };
    }
    if (typeof msg.method !== 'string' || msg.method.length === 0 || msg.method.length > 128) {
      return { ok: false, reason: 'invalid-request', idJson: idJson };
    }
    var params = has(msg, 'params') ? msg.params : {};
    if (params === null || typeof params !== 'object') return { ok: false, reason: 'invalid-request', idJson: idJson };
    var out = { ok: true, kind: hasId ? 'request' : 'notification', id: hasId ? msg.id : null, idJson: idJson,
      method: msg.method, params: params, tool: '', args: {} };
    if (msg.method === 'tools/call') {
      if (typeof params.name !== 'string' || !/^[A-Za-z0-9_.\-]{1,64}$/.test(params.name)) {
        return { ok: false, reason: 'invalid-params', idJson: idJson };
      }
      var args = has(params, 'arguments') ? params.arguments : {};
      if (args === null || typeof args !== 'object' || args instanceof Array) return { ok: false, reason: 'invalid-params', idJson: idJson };
      out.tool = params.name;
      out.args = args;
    }
    return out;
  }

  // ---------------------------------------------------------------- 2. validate tool arguments
  /** Returns {ok:true, args:<normalized>} or {ok:false, message}. */
  function validateArgs(tool, a) {
    var acc;
    switch (tool) {
      case 'get_account_balance':
      case 'get_account_summary':
        acc = accountId(a.account_id);
        return acc ? { ok: true, args: { account_id: acc } } : { ok: false, message: 'account_id must be a 4-12 digit account number.' };
      case 'list_transactions':
        acc = accountId(a.account_id);
        if (!acc) return { ok: false, message: 'account_id must be a 4-12 digit account number.' };
        var limit = has(a, 'limit') ? Number(a.limit) : 10;
        if (!isFinite(limit) || Math.floor(limit) !== limit || limit < 1 || limit > 50) return { ok: false, message: 'limit must be an integer between 1 and 50.' };
        return { ok: true, args: { account_id: acc, limit: limit } };
      case 'transfer_funds':
        var from = accountId(a.from_account);
        var to = accountId(a.to_account);
        if (!from || !to) return { ok: false, message: 'from_account and to_account must be 4-12 digit account numbers.' };
        if (from === to) return { ok: false, message: 'from_account and to_account must differ.' };
        var amount = typeof a.amount === 'string' && /^[0-9]+(\.[0-9]{1,2})?$/.test(a.amount) ? Number(a.amount) : a.amount;
        if (typeof amount !== 'number' || !isFinite(amount) || amount <= 0 || amount > 1000000000) return { ok: false, message: 'amount must be a positive number of SGD.' };
        if (round2(amount) !== amount) return { ok: false, message: 'amount supports at most 2 decimal places.' };
        var memo = has(a, 'memo') && a.memo !== null ? a.memo : '';
        if (typeof memo !== 'string' || memo.length > 140) return { ok: false, message: 'memo must be a string of at most 140 characters.' };
        return { ok: true, args: { from_account: from, to_account: to, amount: amount, memo: memo } };
      case 'get_fx_rate':
        var base = typeof a.base === 'string' ? a.base.toUpperCase() : '';
        var quote = typeof a.quote === 'string' ? a.quote.toUpperCase() : '';
        if (!/^[A-Z]{3}$/.test(base) || !/^[A-Z]{3}$/.test(quote)) return { ok: false, message: 'base and quote must be 3-letter ISO 4217 codes.' };
        return { ok: true, args: { base: base, quote: quote } };
      default:
        return { ok: false, message: 'Unknown tool.' };
    }
  }

  // ---------------------------------------------------------------- 3. authorize (Apigee policy decision)
  /**
   * in: {method, tool, args, allowedToolsAttr, userTokenRequired:boolean, user:null|{...}}
   * out: {allow:true, policy, args?} or {allow:false, reason, message?}
   * Order: method -> tool in product -> user token -> argument validity -> user scope -> transfer limit.
   */
  function authorize(input) {
    var m = input.method;
    if (m === 'initialize' || m === 'ping' || m === 'tools/list' || m.indexOf('notifications/') === 0 || input.kind === 'response') {
      return { allow: true, policy: m === 'tools/list' ? 'tools-filtered' : 'allow' };
    }
    if (m !== 'tools/call') return { allow: false, reason: 'method-not-found' };

    var allowed = parseAllowedTools(input.allowedToolsAttr);
    var known = TOOL_NAMES.indexOf(input.tool) >= 0;
    if (!known) {
      // Unknown names are never echoed back and never reach a backend.
      return allowed.length === TOOL_NAMES.length ? { allow: false, reason: 'unknown-tool' }
        : { allow: false, reason: 'tool-not-in-product' };
    }
    if (allowed.indexOf(input.tool) < 0) {
      return { allow: false, reason: 'tool-not-in-product', message: 'Tool ' + input.tool + ' is not included in your API product.' };
    }

    var needsUser = has(USER_SCOPES, input.tool) && (input.userTokenRequired || input.tool === 'transfer_funds' || input.user);
    if (needsUser && !input.user) return { allow: false, reason: 'user-token-required' };
    if (input.user && !input.user.hasExp) return { allow: false, reason: 'user-token-invalid' };

    // On-behalf-of: a user token is only valid in the hands of the agent app it was delegated to (act.sub).
    if (input.user) {
      if (!input.user.actor) return { allow: false, reason: 'delegation-required' };
      var caller = input.callerApp ? String(input.callerApp) : '';
      if (!caller || input.user.actor !== caller) {
        return { allow: false, reason: 'actor-mismatch',
          message: 'This token lets ' + input.user.actor + ' act for ' + String(input.user.sub || 'the user') +
            '; the calling app is ' + (caller || 'unknown') + '.' };
      }
    }

    var v = validateArgs(input.tool, input.args || {});
    if (!v.ok) return { allow: false, reason: 'invalid-params', message: v.message };

    if (needsUser) {
      var scope = USER_SCOPES[input.tool];
      if (input.user.scopes.indexOf(scope) < 0) {
        return { allow: false, reason: 'user-scope-missing', message: 'The end user is missing the ' + scope + ' scope required for ' + input.tool + '.' };
      }
      if (input.tool === 'transfer_funds' && v.args.amount > input.user.transferLimit) {
        return {
          allow: false, reason: 'user-transfer-limit',
          message: 'Transfer of ' + fmtSgd(v.args.amount) + ' exceeds the transfer limit of ' + fmtSgd(input.user.transferLimit) +
            ' for role ' + String(input.user.role || 'unknown') + '.'
        };
      }
    }
    return { allow: true, policy: 'allow', args: v.args };
  }

  // ---------------------------------------------------------------- 4. tools
  function toolError(text) {
    return { content: [{ type: 'text', text: text }], isError: true };
  }

  function toolOk(data) {
    return { content: [{ type: 'text', text: JSON.stringify(data) }], structuredContent: data, isError: false };
  }

  function band(n) {
    if (n < 10000) return 'under SGD 10k';
    if (n < 50000) return 'SGD 10k-50k';
    if (n < 100000) return 'SGD 50k-100k';
    if (n < 250000) return 'SGD 100k-250k';
    return 'over SGD 250k';
  }

  function runTool(tool, args, user, nowIso) {
    var acct;
    switch (tool) {
      case 'get_account_balance':
        acct = ACCOUNTS[args.account_id];
        if (!acct) return toolError('Account ' + args.account_id + ' not found.');
        return toolOk({ account_id: args.account_id, holder: acct.holder, product: acct.product, currency: acct.currency,
          balance: acct.balance, available_balance: acct.balance, status: acct.status, as_of: nowIso, source: 'cymbal-core-banking (mock)' });
      case 'list_transactions':
        acct = ACCOUNTS[args.account_id];
        if (!acct) return toolError('Account ' + args.account_id + ' not found.');
        var txns = transactions(args.account_id).slice(0, args.limit);
        return toolOk({ account_id: args.account_id, currency: acct.currency, count: txns.length, transactions: txns });
      case 'transfer_funds':
        var from = ACCOUNTS[args.from_account];
        var to = ACCOUNTS[args.to_account];
        if (!from) return toolError('Account ' + args.from_account + ' not found.');
        if (!to) return toolError('Account ' + args.to_account + ' not found.');
        if (args.amount > from.balance) return toolError('Insufficient funds in account ' + args.from_account + '.');
        var ref = 'CYM-TRF-' + String(Date.parse(nowIso) % 100000000) + '-' + Math.floor(Math.random() * 9000 + 1000);
        return toolOk({ status: 'accepted', reference: ref, from_account: args.from_account, to_account: args.to_account,
          amount: args.amount, currency: 'SGD', memo: args.memo, initiated_by: user ? user.sub : null,
          projected_balance: round2(from.balance - args.amount), executed_at: nowIso, simulated: true });
      case 'get_account_summary':
        acct = ACCOUNTS[args.account_id];
        if (!acct) return toolError('Account ' + args.account_id + ' not found.');
        return toolOk({ account: '****' + args.account_id.slice(-4), holder_initials: acct.initials, product: acct.product,
          currency: acct.currency, balance_band: band(acct.balance), status: acct.status });
      case 'get_fx_rate':
        if (!has(SGD_PER, args.base) || !has(SGD_PER, args.quote)) return toolError('Unsupported currency pair ' + args.base + '/' + args.quote + '.');
        var rate = SGD_PER[args.base] / SGD_PER[args.quote];
        return toolOk({ pair: args.base + '/' + args.quote, rate: Math.round(rate * 1000000) / 1000000, type: 'indicative mid-market', as_of: nowIso });
      default:
        return toolError('Unknown tool.');
    }
  }

  // ---------------------------------------------------------------- 5. respond (successful path only)
  /**
   * in: {kind, id, idJson, method, params, tool, args, allowedToolsAttr, user, nowIso}
   * out: {status, body:<string|null>, policy, listed?}
   */
  function respond(input) {
    if (input.kind === 'notification' || input.kind === 'response') return { status: 202, body: null, policy: 'allow' };
    var idJson = safeIdJson(input.idJson);
    var result;
    var policy = 'allow';
    var listed = null;
    switch (input.method) {
      case 'initialize':
        var requested = input.params && input.params.protocolVersion;
        result = {
          protocolVersion: SUPPORTED_PROTOCOLS.indexOf(requested) >= 0 ? requested : DEFAULT_PROTOCOL,
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions: 'Cymbal Bank core banking tools exposed and governed by Apigee. The tools you see depend on your API product.'
        };
        break;
      case 'ping':
        result = {};
        break;
      case 'tools/list':
        var allowed = parseAllowedTools(input.allowedToolsAttr);
        var tools = [];
        for (var i = 0; i < TOOLS.length; i++) if (allowed.indexOf(TOOLS[i].name) >= 0) tools.push(TOOLS[i]);
        listed = tools.length;
        policy = tools.length < TOOLS.length ? 'tools-filtered' : 'allow';
        result = { tools: tools };
        break;
      case 'tools/call':
        var v = validateArgs(input.tool, input.args || {});
        result = v.ok ? runTool(input.tool, v.args, input.user, input.nowIso) : toolError(v.message);
        break;
      default:
        return { status: 400, body: errorBody(idJson, 'method-not-found'), policy: 'method-not-found' };
    }
    return { status: 200, body: '{"jsonrpc":"2.0","id":' + idJson + ',"result":' + JSON.stringify(result) + '}', policy: policy, listed: listed };
  }

  // ---------------------------------------------------------------- 6. errors
  function errorBody(idJson, reason, message) {
    var r = REASONS[reason] || REASONS['internal-error'];
    var policy = REASONS[reason] ? reason : 'internal-error';
    var err = { code: r[1], message: message || r[2], data: { decided_by: 'apigee', policy: policy } };
    return '{"jsonrpc":"2.0","id":' + safeIdJson(idJson) + ',"error":' + JSON.stringify(err) + '}';
  }

  var KEY_FAULTS = ['InvalidApiKey', 'FailedToResolveAPIKey', 'ApiKeyNotApproved', 'InvalidApiKeyForGivenResource',
    'consumer_key_expired', 'invalid_client-app_not_approved', 'DeveloperStatusNotActive', 'app_not_approved'];

  /** Error-flow mapping: explicit reject first, then native fault signals, else internal-error. */
  function faultReason(reject, faultName, flags) {
    if (reject && REASONS[reject]) return reject;
    if (KEY_FAULTS.indexOf(faultName) >= 0 || flags.keyFailed) return 'invalid-api-key';
    if (flags.jwtFailed) return 'user-token-invalid';
    if (faultName === 'QuotaViolation' || flags.quotaFailed) return 'product-quota';
    if (faultName === 'SpikeArrestViolation') return 'rate-limited';
    return 'internal-error';
  }

  function buildError(reason, idJson, message) {
    var r = REASONS[reason] || REASONS['internal-error'];
    return { status: r[0], policy: REASONS[reason] ? reason : 'internal-error', body: errorBody(idJson, reason, message) };
  }

  return {
    SUPPORTED_PROTOCOLS: SUPPORTED_PROTOCOLS,
    TOOLS: TOOLS,
    TOOL_NAMES: TOOL_NAMES,
    ACCOUNTS: ACCOUNTS,
    REASONS: REASONS,
    parse: parse,
    parseAllowedTools: parseAllowedTools,
    userFromClaims: userFromClaims,
    actorFrom: actorFrom,
    validateArgs: validateArgs,
    authorize: authorize,
    respond: respond,
    transactions: transactions,
    faultReason: faultReason,
    buildError: buildError,
    safeIdJson: safeIdJson
  };
})();

if (typeof module !== 'undefined' && module.exports) {
  module.exports = MCP;
}
