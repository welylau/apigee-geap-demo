/**
 * Guided Tour - mission definitions for Agents Meet APIs: Gemini Enterprise Agent Platform × Apigee.
 *
 * Purely declarative: tour-engine.js renders and sequences these. A mission is complete when its
 * last step completes; then the "What just happened?" explainer is shown.
 *
 * Story order (matches the left panel and the diagram subtitle):
 *   overview → S1 both allow → Agent Gateway: who / where / content (S2-S4)
 *   → Apigee: for whom / how much (S5-S6) → partner front door (S7) → IAM: which data (S8) + audit.
 *
 * Step fields (full schema: references/tour.md in the apigee-demo-ui skill)
 *   kind        'action' | 'scenario'
 *   title/body  coachmark copy (string or fn(engine)); body is trusted, authored HTML
 *   target      CSS selector to spotlight ('scenario' steps default to [data-scenario="<id>"])
 *   scenario    scenario id from /api/config (kind 'scenario': pick -> loaded -> running phases)
 *   shade       false = highlight without dimming
 *   action      { label, run(engine) } primary button (kind 'action')
 *   before(engine)  setup when the step is shown
 *   expect      short "Expected:" line
 *   done        { click: selector } | { verdict: ['allowed'|'blocked'|'error'] } | { run: fn(detail, engine) -> bool }
 *   onMiss      fn(detail, engine) -> hint HTML when a run does not satisfy `done`
 *   look        "what to look at" HTML (or fn(engine, detail)) shown on the step-result checkpoint. A passed run
 *               on any step except a mission's last pauses on the result (no dim, evidence outlined) until Next.
 * Mission fields: id (used by ?tour=<id>), title, badge, bonus?, steps[], explainer {title, flow[{text,state,tag}], note, handoff?} | fn(engine)
 */

const click = (sel) => document.querySelector(sel)?.click();
const lastStep = (e) => {
  const steps = e.lastRun?.trace?.steps || [];
  return steps.filter((s) => !s.ok)[0] || steps[steps.length - 1] || null;
};
const policyOf = (e) => e.lastRun?.policy || lastStep(e)?.policy || '—';
const decidedBy = (want) => (d) => d.verdict === 'blocked' && d.decidedBy === want;
const missHint = (want) => (d) => (d.verdict === 'blocked'
  ? `Blocked by <b>${d.decidedBy || 'unknown'}</b> instead of <b>${want}</b>. Check the decision trace below the banner.`
  : `Got <b>${d.verdict}</b>. Agent runs are non-deterministic: press <b>Ask</b> again.`);

export const WELCOME = {
  icon: '🛂',
  title: 'Welcome to Agents Meet APIs',
  subtitle: 'Agent Gateway: where agents go · Apigee: which APIs, for whom, how much · IAM: which data',
  minutes: 7,
  bullets: [
    'One request that both layers allow',
    'Agent Gateway: the wrong agent, a forbidden destination, poisoned content',
    'Apigee: on-behalf-of user limits and a paid third-party API',
    'A partner agent that enters through Apigee alone',
    'The agent reading BigQuery as itself, and the audit log',
  ],
};

export const FINISH = {
  lead: "You've seen how the layers fit together:",
  bullets: [
    'Agent Identity: every agent is its own principal, for Agent Gateway and for Google Cloud IAM',
    'Agent Gateway: who the agent is, where it may go, and a content check that calls Model Armor',
    'Apigee: API products, on-behalf-of user tokens (sub = user, act = agent), limits and paid-API quotas',
    'Same tools, two front doors: internal agents through Agent Gateway + Apigee, partners through Apigee',
    'IAM: the agent reads only the data its identity is granted; every decision is audited',
  ],
};

export const MISSIONS = [
  // ---------------------------------------------------------------- 1
  {
    id: 'architecture', title: 'Meet the architecture', badge: 'Overview',
    steps: [{
      kind: 'action', title: 'Meet the architecture', target: '#viewArchBtn',
      body: `Two agents run on <b>Agent Runtime</b>, each with its own <b>Agent Identity</b>. Every call leaves through
        <b>Agent Gateway</b>; API calls then hit <b>Apigee X</b>.<ul><li>Agent Gateway: <i>may this agent go there?</i></li>
        <li>Apigee: <i>may this app and user do this, and how much?</i></li><li>IAM: <i>which data may this agent read?</i></li></ul>`,
      action: { label: 'Open the diagram', run: () => click('#viewArchBtn') },
      done: { click: '#viewArchBtn' },
    }],
    explainer: {
      title: 'Three control points, one request',
      flow: [
        { text: 'Each agent has its own Agent Identity', state: 'ok', tag: 'Identity' },
        { text: 'Agent Gateway checks the identity and the destination (Agent Registry + IAM access policies)', state: 'ok', tag: 'Agent Gateway' },
        { text: 'Apigee checks the API product, the on-behalf-of user token and quotas', state: 'ok', tag: 'Apigee' },
        { text: 'IAM decides which Google Cloud data the agent may read; every decision is audited', state: 'ok', tag: 'IAM' },
      ],
      note: 'Close the diagram with <kbd>Esc</kbd> when you are ready.',
    },
  },
  // ---------------------------------------------------------------- 2
  {
    id: 'both-allow', title: 'Both layers say yes', badge: '200',
    steps: [{
      kind: 'scenario', scenario: 's1-balance', title: 'S1 · Ask for a balance',
      body: 'Alice asks the RM Agent for a balance. Watch the <b>decision trace</b>: every lane should turn green.',
      expect: 'Allowed · both layers',
      done: { verdict: ['allowed'] },
      onMiss: (d) => `Got <b>${d.verdict}</b>. If the server is not configured, start it with <code>DEMO_MOCK=1</code>.`,
    }],
    explainer: {
      title: 'Allowed by both layers',
      flow: [
        { text: "Agent Gateway: the RM Agent's identity may reach the registered Apigee MCP server", state: 'ok', tag: 'Agent Gateway' },
        { text: "Apigee: the agent's app key maps to the internal-agent product", state: 'ok', tag: 'API product' },
        { text: "Apigee: Alice's delegated token carries accounts:read", state: 'ok', tag: 'User scope' },
        { text: 'Core banking returned the balance', state: 'ok', tag: '200' },
      ],
    },
  },
  // ---------------------------------------------------------------- 3
  {
    id: 'agent-gateway', title: 'Agent Gateway: where may this agent go?', badge: 'Agent Gateway',
    steps: [{
      kind: 'scenario', scenario: 's7-wrong-agent', title: 'S2 · Right tool, wrong agent',
      body: 'The <b>Insights Agent</b> asks for the same balance as S1. Same code, same tool, but a <b>different Agent Identity</b>.',
      expect: 'Blocked by Agent Gateway · 403',
      look: 'The trace stops at <b>Agent Gateway</b>: the Insights Agent\'s identity is not on the allowlist. Apigee never sees the call.',
      done: { run: decidedBy('agent-gateway') }, onMiss: missHint('agent-gateway'),
    }, {
      kind: 'scenario', scenario: 's2-exfil', title: 'S3 · Exfiltrate to a webhook',
      body: 'The RM Agent is talked into posting client data to <code>webhook.site</code>. That host is not in Agent Registry.',
      expect: 'Blocked by Agent Gateway',
      look: 'The balance lookup passed, then <code>share_via_webhook</code> was refused at <b>Agent Gateway</b>: <code>webhook.site</code> is not in Agent Registry, so default deny applies.',
      done: { run: decidedBy('agent-gateway') }, onMiss: missHint('agent-gateway'),
    }, {
      kind: 'scenario', scenario: 's3-injection', title: 'S4 · A poisoned third-party tool',
      body: 'The credit bureau (behind Apigee) returns hidden instructions. Agent Gateway\'s <b>content check</b> calls <b>Model Armor</b> on the response.',
      expect: 'Blocked by Agent Gateway (Model Armor)',
      done: { run: decidedBy('agent-gateway') }, onMiss: missHint('agent-gateway'),
    }],
    explainer: (e) => ({
      title: 'Who, where, and is it safe?',
      flow: [
        { text: "Wrong agent: the allowlist names the RM Agent's identity, not the Insights Agent's", state: 'fail', tag: 'Identity' },
        { text: 'Unregistered destination: no access policy allows it, so the gateway denies by default', state: 'fail', tag: 'Registry' },
        { text: 'Poisoned tool response: Model Armor flags the prompt injection before the agent reads it', state: 'fail', tag: 'Model Armor' },
        { text: `Last policy: ${policyOf(e)}`, state: 'ok', tag: 'Audit' },
      ],
      note: 'Only a control on the <b>agent\'s own egress path</b> can judge the agent itself, and traffic that never goes to your APIs.',
    }),
  },
  // ---------------------------------------------------------------- 4
  {
    id: 'apigee', title: 'Apigee: for whom, and how much?', badge: 'Apigee',
    steps: [{
      kind: 'scenario', scenario: 's4-user-limit', title: 'S5 · Teller over their limit',
      body: 'Bob is a teller. The <b>agent</b> may use <code>transfer_funds</code>, but <b>Bob</b> may only move SGD 10k.',
      expect: 'Blocked by Apigee · 403',
      look: 'Check <b>On behalf of</b> and <b>Delegated to</b>: the agent may call <code>transfer_funds</code>, but Bob\'s SGD 10k limit makes <b>Apigee</b> refuse SGD 50k.',
      done: { run: decidedBy('apigee') }, onMiss: missHint('apigee'),
    }, {
      kind: 'scenario', scenario: 's5-third-party-quota', title: 'S6 · A paid third-party API',
      body: 'Credit bureau lookups cost money. Apigee fronts the bureau and meters the agent\'s app: <b>3 lookups per minute</b>.',
      expect: 'First 3 allowed, then blocked by Apigee · 429',
      done: { run: decidedBy('apigee') }, onMiss: missHint('apigee'),
    }],
    explainer: {
      title: 'The agent was allowed; the user and the budget were not',
      flow: [
        { text: 'Agent Gateway: the agent may reach the Apigee MCP server and the bureau', state: 'ok', tag: 'Agent Gateway' },
        { text: "Bob's token is delegated: sub = teller-bob, act = the RM Agent's Apigee app", state: 'ok', tag: 'On behalf of' },
        { text: "Bob's transfer_limit 10,000 < amount 50,000", state: 'fail', tag: 'User limit' },
        { text: 'Paid credit bureau: 3 calls / min per app, the 4th is refused', state: 'fail', tag: 'Quota' },
      ],
      note: 'Business rules and API economics live with the API, not the agent.',
    },
  },
  // ---------------------------------------------------------------- 5
  {
    id: 'partner', title: 'A partner at the front door', badge: 'Partner',
    steps: [{
      kind: 'scenario', scenario: 's6-partner', title: 'S7 · FinPal, a partner agent',
      body: 'FinPal runs <b>outside Google Cloud</b>, so Agent Gateway is not in its path. It reaches the <b>same MCP tools</b> through Apigee with its own key.',
      expect: 'Sees 2 tools; 6th call blocked · 429',
      done: { run: decidedBy('apigee') }, onMiss: missHint('apigee'),
    }],
    explainer: {
      title: 'Same tools, second front door',
      flow: [
        { text: 'No Agent Runtime, no Agent Gateway: the partner calls Apigee directly', state: 'skip', tag: 'Agent Gateway' },
        { text: 'Partner product: tools/list filtered to 2 of 5 tools', state: 'ok', tag: 'Product' },
        { text: 'Partner quota: 5 calls / minute, the 6th is refused', state: 'fail', tag: 'Quota' },
        { text: 'Internal agents: Agent Gateway + Apigee. Partners: Apigee', state: 'ok', tag: 'Positioning' },
      ],
    },
  },
  // ---------------------------------------------------------------- 6
  {
    id: 'agent-identity', title: 'The agent reads data as itself', badge: 'IAM',
    steps: [{
      kind: 'scenario', scenario: 's8-agent-iam', title: 'S8 · The agent reads BigQuery as itself',
      body: 'No API key, no service account: the RM Agent calls BigQuery with its <b>own identity</b>. IAM grants it the KYC table only.',
      expect: 'KYC row returned, HR lookup blocked by Google IAM · 403',
      look: 'The KYC row came back, then <b>Google IAM</b> refused the HR table: the RM Agent\'s own identity has no grant on it. No key, no service account.',
      done: { run: decidedBy('iam') }, onMiss: missHint('iam'),
    }, {
      kind: 'action', title: 'Every decision is audited', target: '#adminTab',
      body: 'The audit log shows each run with the <b>layer that decided</b>: Agent Gateway, Apigee or IAM.',
      action: { label: 'Open audit log', run: () => click('#adminTab') },
      done: { click: '#adminTab, #btnOpenAdmin' },
    }],
    explainer: {
      title: 'Each agent is its own principal',
      flow: [
        { text: 'IAM: the RM Agent identity has bigquery.dataViewer on the KYC table', state: 'ok', tag: 'IAM allow' },
        { text: 'No grant on the HR table, so BigQuery refuses the agent', state: 'fail', tag: 'IAM deny' },
        { text: 'The same identity Agent Gateway checked in S2 is the one IAM checks here', state: 'ok', tag: 'Identity' },
        { text: 'The audit log shows which layer decided, for which agent and user', state: 'ok', tag: 'Audit' },
      ],
      note: 'Identity is per agent: grant, audit and revoke each agent separately.',
    },
  },
];
