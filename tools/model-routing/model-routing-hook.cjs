'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const deny = reason => ({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } });
const ask = reason => ({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'ask', permissionDecisionReason: reason } });
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function run(event) {
  const guidance = 'Use agent_workspace_discover_models and agent_workspace_dispatch_agent. Unmanaged subagents are blocked in this workspace. Approve model-routing-policy.json through the Technical Workspace: Approve Model Routing Policy command before dispatch.';
  if (event.hook_event_name === 'SessionStart') {
    return { hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: guidance } };
  }
  if (event.hook_event_name === 'SubagentStart') {
    return { continue: false, stopReason: guidance };
  }
  if (event.hook_event_name !== 'PreToolUse' || typeof event.tool_name !== 'string') {
    return deny('Malformed model-routing hook input.');
  }
  const toolName = event.tool_name.replace(/[^a-z]/gi, '').toLowerCase();
  if (/(runsubagent|runagent|delegateagent)$/.test(toolName) || ['task', 'agent'].includes(toolName)) {
    return deny(guidance);
  }
  if (event.tool_name === 'agent_workspace_dispatch_agent') {
    const input = event.tool_input;
    if (!input || !uuid.test(input.requestId) || !/^[a-z][a-z0-9-]{0,63}$/.test(input.agentId)
      || typeof input.task !== 'string' || !input.task.trim() || input.task.length > 32000
      || (input.context !== undefined && (typeof input.context !== 'string' || input.context.length > 128000))
      || (input.reviewOf !== undefined && !uuid.test(input.reviewOf))
      || typeof event.session_id !== 'string' || !event.session_id || event.session_id.length > 256
      || typeof event.tool_use_id !== 'string' || !event.tool_use_id || event.tool_use_id.length > 256) {
      return deny('Invalid routed dispatch input or missing host session/tool identity.');
    }
    const root = fs.realpathSync(path.resolve(__dirname, '../..'));
    if (input.workspaceFolder && fs.realpathSync(input.workspaceFolder) !== root) {
      return deny('Dispatch workspace does not match the hook workspace.');
    }
    let directory = root;
    for (const segment of ['.github', 'model-routing', 'receipts']) {
      directory = path.join(directory, segment);
      if (!fs.existsSync(directory)) { fs.mkdirSync(directory); }
      if (fs.lstatSync(directory).isSymbolicLink() || !fs.statSync(directory).isDirectory()) {
        return deny('Routing receipt directory must not be a symlink or non-directory.');
      }
    }
    const canonical = [root, input.requestId, input.agentId, input.task.trim(), input.context ?? '', input.reviewOf ?? null];
    const receipt = {
      schemaVersion: 1, root, sessionId: event.session_id, toolUseId: event.tool_use_id,
      inputHash: crypto.createHash('sha256').update(JSON.stringify(canonical)).digest('hex'),
      createdAt: Date.now(),
    };
    try {
      fs.writeFileSync(path.join(directory, `${input.requestId}.json`), JSON.stringify(receipt), { flag: 'wx', mode: 0o600 });
    } catch {
      return deny('Receipt already exists or cannot be written. Use a new requestId; do not reuse a prior dispatch.');
    }
    return ask('Routed delegation requires host confirmation and a separately approved policy. This receipt is only hook-liveness evidence.');
  }
  if (/edit|patch|replace|create|write|terminal/.test(toolName)
    && /\.github[\\/]+(?:hooks|agents|model-routing)|model-routing-hook|model-routing-policy/i.test(JSON.stringify(event.tool_input))) {
    return ask('Routing controls and agent definitions require owner review. Changing them invalidates routing approval.');
  }
  return {};
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  input += chunk;
  if (Buffer.byteLength(input) > 262144) {
    process.stdout.write(JSON.stringify(deny('Hook input exceeds 256 KiB.')) + '\n');
    process.exit(2);
  }
});
process.stdin.on('end', () => {
  try { process.stdout.write(JSON.stringify(run(JSON.parse(input))) + '\n'); }
  catch { process.stdout.write(JSON.stringify(deny('Routing hook could not validate this request.')) + '\n'); }
});
