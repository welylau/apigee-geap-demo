/*
 * extproc-lib.js  (cymbal-ge-demo-extproc) - pure functions, ES5, also loaded by node tests.
 *
 * The Agent Gateway sends EVERY governed agent request to this no-target proxy (authz extension,
 * CONTENT_AUTHZ). We only govern the credit-bureau host; everything else must pass untouched.
 *
 * classify() decides:
 *   governed  - Host header (port stripped, lowercased) is in the configured credit-bureau host list
 *   count     - governed AND it is a paid lookup: a JSON-RPC "tools/call" POST. If the body is not
 *               available (apigee-request-body not enabled) every POST to the host is counted instead.
 *               initialize / notifications / tools/list are NOT counted, so the MCP handshake does not
 *               burn the 3-per-2-minutes budget.
 *   quotaKey  - per agent identity when a configured identity header is present, else per host.
 *
 * Identity: the documented Agent Gateway / ext-proc contract does not name an agent-identity header
 * (checked 2026-11-17). Candidate headers are configurable (identity_headers property); for
 * x-forwarded-client-cert the SPIFFE URI= value is used. Unverified until seen in a debug session.
 */
var EXTPROC = (function () {
  'use strict';

  function splitList(s) {
    var out = [];
    var parts = String(s || '').toLowerCase().split(/[\s,]+/);
    for (var i = 0; i < parts.length; i++) if (parts[i]) out.push(parts[i]);
    return out;
  }

  function normHost(h) {
    if (h === null || h === undefined) return '';
    var s = String(h).toLowerCase().replace(/^\s+|\s+$/g, '');
    if (s.charAt(0) === '[') return s; // IPv6 literal; never a credit-bureau host
    var i = s.indexOf(':');
    return i >= 0 ? s.slice(0, i) : s;
  }

  function sanitizeKey(v) {
    return String(v).replace(/[^A-Za-z0-9:\/._@\-]/g, '_').slice(0, 256);
  }

  function identityFrom(headers, names) {
    for (var i = 0; i < names.length; i++) {
      var v = headers[names[i]];
      if (v === null || v === undefined || String(v) === '') continue;
      v = String(v);
      if (names[i] === 'x-forwarded-client-cert') {
        var m = /URI=([^;,]+)/.exec(v);
        if (!m) continue;
        v = m[1];
      }
      return { key: 'id:' + sanitizeKey(v), source: names[i] };
    }
    return null;
  }

  function isPaidLookup(verb, bodyText) {
    if (String(verb).toUpperCase() !== 'POST') return false;
    if (bodyText === null || bodyText === undefined || String(bodyText) === '') return true; // no body forwarded: count POSTs
    var msg;
    try { msg = JSON.parse(String(bodyText)); } catch (e) { return true; }
    var list = msg instanceof Array ? msg : [msg];
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].method === 'tools/call') return true;
    }
    return false;
  }

  /** in: {host, verb, bodyText, headers:{lowercase name -> value}, cbHosts, identityHeaders} */
  function classify(input) {
    var host = normHost(input.host);
    var hosts = splitList(input.cbHosts);
    if (!host || hosts.indexOf(host) < 0) return { governed: false, count: false };
    var id = identityFrom(input.headers || {}, splitList(input.identityHeaders));
    return {
      governed: true,
      count: isPaidLookup(input.verb, input.bodyText),
      quotaKey: id ? id.key : 'host:' + host,
      keySource: id ? id.source : 'host'
    };
  }

  return { classify: classify, normHost: normHost, isPaidLookup: isPaidLookup, splitList: splitList };
})();

if (typeof module !== 'undefined' && module.exports) {
  module.exports = EXTPROC;
}
