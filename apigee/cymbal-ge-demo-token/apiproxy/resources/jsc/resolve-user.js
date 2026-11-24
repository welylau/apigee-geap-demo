/*
 * JS-Resolve-User (cymbal-ge-demo-token, request flow)
 * Maps the requested demo persona to its claims, and the requested agent (actor) to the Apigee app it is
 * delegated to. Body: {"user":"rm-alice"|"teller-bob","actor":"rm-agent"|"insights-agent"}.
 * The result is an on-behalf-of token: sub = the user, act = {sub: <agent's Apigee app>, ...} (RFC 8693).
 * The MCP server only honours the token when the calling x-api-key belongs to that same app.
 * Only the personas and agents below exist; anything else is rejected (fail closed). Input is treated as
 * untrusted: size, type and an exact-match allowlist are checked; nothing from the body is echoed back.
 */
var USERS = {
  'rm-alice': {
    role: 'relationship_manager',
    scope: 'accounts:read payments:write',
    transfer_limit: 100000,
    name: 'Alice Tan (Relationship Manager)'
  },
  'teller-bob': {
    role: 'teller',
    scope: 'accounts:read payments:write',
    transfer_limit: 10000,
    name: 'Bob Lim (Teller)'
  }
};

// Agents a user may delegate to, and the Apigee developer app each agent calls with.
var ACTORS = {
  'rm-agent': { client_id: 'cymbal-ge-demo-agent-app', name: 'RM Agent' },
  'insights-agent': { client_id: 'cymbal-ge-demo-insights-app', name: 'Insights Agent' }
};

function resolveUser(bodyText) {
  if (!bodyText || bodyText.length > 2048) {
    return { reject: 'invalid-request' };
  }
  var body;
  try {
    body = JSON.parse(bodyText);
  } catch (e) {
    return { reject: 'invalid-request' };
  }
  if (!body || typeof body !== 'object' || typeof body.user !== 'string') {
    return { reject: 'invalid-request' };
  }
  if (!Object.prototype.hasOwnProperty.call(USERS, body.user)) {
    return { reject: 'unknown-user' };
  }
  if (typeof body.actor !== 'string' || !Object.prototype.hasOwnProperty.call(ACTORS, body.actor)) {
    return { reject: 'unknown-actor' };
  }
  var u = USERS[body.user];
  var a = ACTORS[body.actor];
  return {
    sub: body.user,
    role: u.role,
    scope: u.scope,
    transfer_limit: u.transfer_limit,
    name: u.name,
    actor: body.actor,
    act: { sub: a.client_id, agent: body.actor, name: a.name }
  };
}

if (typeof context !== 'undefined') {
  var r = resolveUser(context.getVariable('request.content'));
  if (r.reject) {
    context.setVariable('cymbal.reject', r.reject);
  } else {
    context.setVariable('cymbal.sub', r.sub);
    context.setVariable('cymbal.role', r.role);
    context.setVariable('cymbal.scope', r.scope);
    context.setVariable('cymbal.transfer_limit', String(r.transfer_limit));
    context.setVariable('cymbal.display_name', r.name);
    context.setVariable('cymbal.actor', r.actor);
    context.setVariable('cymbal.act_client', r.act.sub);
    context.setVariable('cymbal.act_json', JSON.stringify(r.act));
  }
}

if (typeof module !== 'undefined') {
  module.exports = { resolveUser: resolveUser, USERS: USERS, ACTORS: ACTORS };
}
