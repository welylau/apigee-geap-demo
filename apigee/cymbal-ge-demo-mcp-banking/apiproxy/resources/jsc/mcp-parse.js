/*
 * JS-Mcp-Parse (request flow, before VerifyAPIKey). Uses MCP from mcp-lib.js (IncludeURL).
 * Sets mcp.* for later steps; on a malformed message sets cymbal.reject so RF-Reject fires.
 */
(function () {
  var p = MCP.parse(context.getVariable('request.content'));
  context.setVariable('mcp.id_json', p.idJson || 'null');
  if (!p.ok) {
    context.setVariable('cymbal.reject', p.reason);
    context.setVariable('mcp.method', '');
    return;
  }
  context.setVariable('mcp.kind', p.kind);
  context.setVariable('mcp.method', p.method || '');
  context.setVariable('mcp.tool', p.tool || '');
  context.setVariable('mcp.args_json', JSON.stringify(p.args || {}));
  context.setVariable('mcp.params_json', JSON.stringify(p.params || {}));
})();
