/*
 * JS-Extproc-Classify (request flow). Never throws (continueOnError on the policy + try/catch here):
 * a script failure must not deny the agent's unrelated traffic. On any error nothing is governed.
 */
(function () {
  context.setVariable('cymbal.cb_governed', 'false');
  context.setVariable('cymbal.cb_count', 'false');
  try {
    var P = 'propertyset.extproc.';
    var idNames = EXTPROC.splitList(context.getVariable(P + 'identity_headers'));
    var headers = {};
    for (var i = 0; i < idNames.length; i++) {
      headers[idNames[i]] = context.getVariable('request.header.' + idNames[i]);
    }
    var host = context.getVariable('request.header.host');
    if (host === null || String(host) === '') host = context.getVariable('request.header.:authority');
    var c = EXTPROC.classify({
      host: host,
      verb: context.getVariable('request.verb'),
      bodyText: context.getVariable('request.content'),
      headers: headers,
      cbHosts: context.getVariable(P + 'credit_bureau_hosts'),
      identityHeaders: context.getVariable(P + 'identity_headers')
    });
    if (c.governed) {
      context.setVariable('cymbal.cb_governed', 'true');
      context.setVariable('cymbal.cb_count', c.count ? 'true' : 'false');
      context.setVariable('cymbal.quota_key', c.quotaKey);
      context.setVariable('cymbal.quota_key_source', c.keySource);
    }
  } catch (e) {
    context.setVariable('cymbal.cb_error', 'classify-failed');
  }
})();
