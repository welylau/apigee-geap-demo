/*
 * JS-Llm-Route (proxy request flow, after VA-VerifyKey, before LTQ-Enforce).
 * Validates the Vertex path, rejects streaming, applies the model allowlist and the cymbal-auto alias.
 * The resolved backend model id goes to ai.upstream_model: both LLMTokenQuota policies key on it and the
 * API product's llmOperations list the same ids (apigee-x-ai-gateway token-quota.md).
 */
(function () {
  var P = 'propertyset.llm.';
  // Fail closed when the product has no LLM token budget (token-quota.md "missing product quota" guard).
  var limit = context.getVariable('verifyapikey.VA-VerifyKey.apiproduct.developer.llmQuota.limit');
  if (limit === null || String(limit) === '') {
    context.setVariable('cymbal.reject', 'llm-budget-not-configured');
    return;
  }
  var r = LLM.route({
    pathsuffix: context.getVariable('proxy.pathsuffix'),
    query: context.getVariable('request.querystring'),
    bodyText: context.getVariable('request.content'),
    config: {
      alias: context.getVariable(P + 'alias'),
      defaultModel: context.getVariable(P + 'default_model'),
      routedModel: context.getVariable(P + 'routed_model'),
      threshold: Number(context.getVariable(P + 'auto_threshold_chars')),
      allowedModels: context.getVariable(P + 'allowed_models')
    }
  });
  if (!r.ok) {
    context.setVariable('cymbal.reject', r.reason);
    return;
  }
  context.setVariable('ai.upstream_model', r.model);
  context.setVariable('ai.alias', r.alias);
  context.setVariable('ai.route', r.route);
  context.setVariable('ai.prompt_chars', String(r.chars));
  context.setVariable('ai.policy', r.alias ? 'model-routing' : 'allow');
})();
