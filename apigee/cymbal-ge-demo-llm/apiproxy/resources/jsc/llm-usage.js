/*
 * JS-Llm-Usage (proxy response flow, before LTQ-Count). Marks usage valid only for a non-negative
 * numeric usageMetadata.totalTokenCount; LTQ-Count is skipped otherwise (never counted as zero).
 */
(function () {
  var u = LLM.usage(context.getVariable('response.content'));
  context.setVariable('ai.usage.valid', u.valid ? 'true' : 'false');
  if (u.valid) {
    context.setVariable('ai.usage.total', String(u.total));
    context.setVariable('ai.usage.prompt', String(u.prompt));
    context.setVariable('ai.usage.output', String(u.output));
    context.setVariable('ai.usage.thinking', String(u.thinking));
  } else {
    context.setVariable('ai.usage.total', 'unknown');
  }
})();
