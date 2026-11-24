/*
 * JS-Bureau-Classify (request flow, after VA-VerifyKey). Reads request.content only (never rewrites it).
 * Sets bureau.paid ("true" only for tools/call) for Q-Credit-Bureau, or cymbal.reject for malformed input.
 */
(function () {
  var c = BUREAU.classify(context.getVariable('request.content'));
  context.setVariable('bureau.id_json', c.idJson || 'null');
  if (!c.ok) {
    context.setVariable('cymbal.reject', c.reason);
    context.setVariable('bureau.paid', 'false');
    return;
  }
  context.setVariable('bureau.method', c.method);
  context.setVariable('bureau.paid', c.paid ? 'true' : 'false');
})();
