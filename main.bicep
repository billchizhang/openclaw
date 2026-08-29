@description('Location for all resources.')
param location string = resourceGroup().location

@description('Name of the Container Apps Environment.')
param environmentName string = 'openclaw-workspace-env'

@description('Name of the OpenClaw Container App.')
param containerAppName string = 'openclaw-gateway'

@description('The full image tag from GitHub Actions (e.g., myacr.azurecr.io/my-openclaw:abc1234).')
param containerImage string

@description('The ACR login server (e.g., myacr.azurecr.io).')
param registryServer string

@description('The ACR username (usually the registry name).')
param registryUsername string

@description('The ACR password.')
@secure()
param registryPassword string

@description('Your static token to lock down the OpenClaw dashboard.')
@secure()
param openclawStaticToken string

@description('OpenAI API Key for the execution model')
@secure()
param openAiApiKey string

@description('Anthropic API Key for the reasoning model')
@secure()
param anthropicApiKey string

@description('Gemini API Key for web search grounding')
@secure()
param geminiApiKey string

@description('DeepSeek API Key for the native deepseek provider (platform.deepseek.com).')
@secure()
param deepSeekApiKey string

@description('Slack App Token (starts with xapp-) for socket mode')
@secure()
param slackAppToken string

@description('Slack Bot Token (starts with xoxb-) for bot actions')
@secure()
param slackBotToken string

@description('JSON array of Slack member IDs allowed to interact with the bot (e.g., \'["U12345","U67890"]\').')
param slackAllowedMembers string = '["*"]'

@description('Name of the Azure OpenAI resource for token budget fallback.')
param openAiAccountName string = 'openclaw-aoai-${uniqueString(resourceGroup().id)}'

@description('SKU for the Azure OpenAI resource.')
param openAiSku string = 'S0'

@description('GPT-4o deployment capacity in thousands of tokens per minute.')
param gpt4oCapacity int = 10

// 1. Log Analytics Workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${environmentName}-logs'
  location: location
  tags: {
    Component: 'OpenClaw'
  }
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// 2. Storage Account for Persistent Memory
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: 'ocdata${uniqueString(resourceGroup().id)}'
  location: location
  tags: {
    Component: 'OpenClaw'
  }
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}

// 3. Azure File Share (The "Trailer")
resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2022-09-01' = {
  name: '${storageAccount.name}/default/openclaw-workspace'
}

// 3b. Azure OpenAI Resource (Token Budget Fallback)
resource openAiAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: openAiAccountName
  location: location
  tags: {
    Component: 'OpenClaw'
    Purpose: 'Token Budget Fallback'
  }
  kind: 'OpenAI'
  sku: {
    name: openAiSku
  }
  properties: {
    customSubDomainName: openAiAccountName
    publicNetworkAccess: 'Enabled'
  }
}

// 3c. GPT-4o Model Deployment
resource gpt4oDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAiAccount
  name: 'gpt-4o'
  sku: {
    name: 'Standard'
    capacity: gpt4oCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2024-11-20'
    }
  }
}

// 4. Container Apps Environment
resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: environmentName
  location: location
  tags: {
    Component: 'OpenClaw'
  }
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }

  // Register the File Share to the Environment
  resource storage 'storages@2023-05-01' = {
    name: 'openclaw-mount'
    dependsOn: [
      fileShare // Prevents the race condition
    ]
    properties: {
      azureFile: {
        accountName: storageAccount.name
        accountKey: storageAccount.listKeys().keys[0].value
        shareName: 'openclaw-workspace'
        accessMode: 'ReadWrite'
      }
    }
  }
}

// 5. The OpenClaw Gateway Container App
resource openclawApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  tags: {
    Component: 'OpenClaw'
  }
  dependsOn: [
    containerAppEnv::storage
  ]
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 18789
      }
      secrets: [
        {
          name: 'acr-password'
          value: registryPassword
        }
        {
          name: 'gateway-token'
          value: openclawStaticToken
        }
        {
          name: 'openai-api-key'
          value: openAiApiKey
        }
        {
          name: 'anthropic-api-key'
          value: anthropicApiKey
        }
        {
          name: 'gemini-api-key'
          value: geminiApiKey
        }
        {
          name: 'deepseek-api-key'
          value: deepSeekApiKey
        }
        {
          name: 'slack-app-token'
          value: slackAppToken
        }
        {
          name: 'slack-bot-token'
          value: slackBotToken
        }
        {
          name: 'azure-openai-api-key'
          value: openAiAccount.listKeys().key1
        }
      ]
      registries: [
        {
          server: registryServer
          username: registryUsername
          passwordSecretRef: 'acr-password'
        }
      ]
    }
    template: {
      volumes: [
        {
          name: 'openclaw-volume'
          storageType: 'AzureFile'
          storageName: 'openclaw-mount'
        }
      ]
      containers: [
        {
          name: 'openclaw-core'
          image: containerImage
          command: [
            '/bin/sh'
          ]
          args: [
            '-c'
            '''
cat << 'EOF' > /tmp/patch.js
const fs = require('fs');
['chmod', 'fchmod', 'chown', 'fchown'].forEach(f => {
  fs[f] = (...args) => { const cb = args.pop(); if (typeof cb === 'function') cb(null); };
  fs[f + 'Sync'] = () => {};
  if (fs.promises && fs.promises[f]) fs.promises[f] = async () => {};
});
EOF
cat << 'EOF' > /tmp/repair-config.js
const fs = require('fs');
const configPath = '/home/node/.openclaw/openclaw.json';
if (!fs.existsSync(configPath)) {
  process.exit(0);
}
// A container killed mid-write leaves truncated JSON on the file share. Parsing that would abort
// startup under `set -e`, so fall back to the backup and let doctor rebuild from a clean slate.
function readConfig(candidatePath) {
  try {
    return JSON.parse(fs.readFileSync(candidatePath, 'utf8'));
  } catch {
    return null;
  }
}
const cfg = readConfig(configPath) ?? readConfig(`${configPath}.bak`);
if (!cfg || typeof cfg !== 'object') {
  console.error('WARN: openclaw.json unreadable; leaving it for doctor to rebuild.');
  process.exit(0);
}
if (cfg.meta && typeof cfg.meta === 'object') {
  delete cfg.meta.lastTouchedAt;
  if (Object.keys(cfg.meta).length === 0) {
    delete cfg.meta;
  }
}
if (cfg.commands && typeof cfg.commands === 'object') {
  delete cfg.commands.ownerDisplay;
  delete cfg.commands.ownerDisplaySecret;
}
// Retired Slack streaming aliases. The Slack plugin owns a doctor migration for these, but it only
// runs once plugin discovery succeeds — and these keys make the config invalid before that can run.
// Canonical shape: channels.slack.streaming.{mode,block.enabled,block.coalesce,nativeTransport}.
function migrateSlackStreamingEntry(entry) {
  if (!entry || typeof entry !== 'object') {
    return;
  }
  const nextStreaming =
    entry.streaming && typeof entry.streaming === 'object' && !Array.isArray(entry.streaming)
      ? { ...entry.streaming }
      : {};
  if (typeof entry.streaming === 'boolean') {
    nextStreaming.mode = entry.streaming ? 'partial' : 'off';
  } else if (typeof entry.streaming === 'string') {
    nextStreaming.mode = entry.streaming;
  }
  if (typeof entry.streamMode === 'string' && nextStreaming.mode === undefined) {
    nextStreaming.mode = entry.streamMode;
  }
  if (typeof entry.blockStreaming === 'boolean') {
    nextStreaming.block = {
      ...(typeof nextStreaming.block === 'object' && nextStreaming.block ? nextStreaming.block : {}),
      enabled: entry.blockStreaming,
    };
  }
  if (entry.blockStreamingCoalesce && typeof entry.blockStreamingCoalesce === 'object') {
    nextStreaming.block = {
      ...(typeof nextStreaming.block === 'object' && nextStreaming.block ? nextStreaming.block : {}),
      coalesce: entry.blockStreamingCoalesce,
    };
  }
  if (typeof entry.nativeStreaming === 'boolean') {
    nextStreaming.nativeTransport = entry.nativeStreaming;
  }
  if (typeof entry.chunkMode === 'string') {
    nextStreaming.chunkMode = entry.chunkMode;
  }
  delete entry.blockStreaming;
  delete entry.blockStreamingCoalesce;
  delete entry.nativeStreaming;
  delete entry.streamMode;
  delete entry.chunkMode;
  if (typeof entry.streaming !== 'object' || entry.streaming === null || Array.isArray(entry.streaming)) {
    delete entry.streaming;
  }
  if (Object.keys(nextStreaming).length > 0) {
    entry.streaming = nextStreaming;
  }
}
const slack = cfg.channels && typeof cfg.channels === 'object' ? cfg.channels.slack : undefined;
if (slack && typeof slack === 'object') {
  migrateSlackStreamingEntry(slack);
  if (slack.accounts && typeof slack.accounts === 'object') {
    for (const account of Object.values(slack.accounts)) {
      migrateSlackStreamingEntry(account);
    }
  }
}
// A plugins.load.paths entry that no longer exists on disk invalidates the whole config, which
// aborts plugin discovery before any channel doctor contract can run its own migrations.
// `config set` is NOT allowed against an invalid config, so this must be repaired before any
// subsequent openclaw config mutation or gateway.mode will stay unset.
if (cfg.plugins && typeof cfg.plugins === 'object') {
  if (cfg.plugins.load && typeof cfg.plugins.load === 'object') {
    const paths = cfg.plugins.load.paths;
    if (Array.isArray(paths)) {
      const present = paths.filter((p) => typeof p === 'string' && fs.existsSync(p));
      if (present.length > 0) {
        cfg.plugins.load.paths = present;
      } else {
        delete cfg.plugins.load.paths;
        if (Object.keys(cfg.plugins.load).length === 0) {
          delete cfg.plugins.load;
        }
      }
    }
  }
  // Drop stale plugin entries that are not present in this image. Leaving them in
  // plugins.entries emits a warning on every subsequent `config set`.
  if (cfg.plugins.entries && typeof cfg.plugins.entries === 'object') {
    delete cfg.plugins.entries.whatsapp;
    if (
      cfg.plugins.entries['token-budget'] &&
      !fs.existsSync('/app/custom-plugins/token-budget')
    ) {
      delete cfg.plugins.entries['token-budget'];
    }
    if (Object.keys(cfg.plugins.entries).length === 0) {
      delete cfg.plugins.entries;
    }
  }
}
if (cfg.agents && typeof cfg.agents === 'object') {
  const entries = cfg.agents.entries && typeof cfg.agents.entries === 'object'
    ? { ...cfg.agents.entries }
    : {};
  if (Array.isArray(cfg.agents.list)) {
    for (const entry of cfg.agents.list) {
      if (entry && typeof entry === 'object' && typeof entry.id === 'string' && entry.id.trim()) {
        entries[entry.id] = { ...(entries[entry.id] ?? {}), ...entry };
      }
    }
    delete cfg.agents.list;
  }
  // The entry key is the agent id; the keyed schema rejects a nested "id" field.
  for (const entry of Object.values(entries)) {
    if (entry && typeof entry === 'object') {
      delete entry.id;
    }
  }
  const ids = Object.keys(entries).filter((id) => entries[id] && typeof entries[id] === 'object');
  if (ids.length > 0) {
    // Schema requires exactly one default=true entry. Prefer planner over any stale
    // default carried on the Azure File Share, which would otherwise win by key order.
    const defaults = ids.filter((id) => entries[id].default === true);
    const chosen = ids.includes('planner') ? 'planner' : (defaults[0] ?? ids[0]);
    for (const id of ids) {
      if (id === chosen) {
        entries[id].default = true;
      } else {
        delete entries[id].default;
      }
    }
    cfg.agents.entries = entries;
  }
}
// Apply the desired deployment config in ONE write. Each `openclaw config set` boots a full
// Node process and re-discovers MCP tools (~6s each); 25+ of those never finish before ACA
// recycles the replica. Mutate in-process, then doctor once.
function parseJsonEnv(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  try {
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}
cfg.gateway = {
  ...(cfg.gateway && typeof cfg.gateway === 'object' ? cfg.gateway : {}),
  mode: 'local',
  bind: 'lan',
  trustedProxies: ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'],
  // Keep CLI (`openclaw logs`, etc.) and the gateway on the same token. A stale
  // gateway.auth.token on the file share causes token_mismatch against OPENCLAW_GATEWAY_TOKEN.
  auth: {
    ...(cfg.gateway && cfg.gateway.auth && typeof cfg.gateway.auth === 'object'
      ? cfg.gateway.auth
      : {}),
    mode: 'token',
    token: '${OPENCLAW_GATEWAY_TOKEN}',
  },
  controlUi: {
    ...(cfg.gateway && cfg.gateway.controlUi && typeof cfg.gateway.controlUi === 'object'
      ? cfg.gateway.controlUi
      : {}),
    allowedOrigins: [process.env.OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS].filter(Boolean),
  },
  // OpenAI-compatible HTTP API (/v1/chat/completions, /v1/responses, /v1/models) for
  // programmatic prompts. Bearer auth = OPENCLAW_GATEWAY_TOKEN; treat as operator access.
  http: {
    ...(cfg.gateway && cfg.gateway.http && typeof cfg.gateway.http === 'object' ? cfg.gateway.http : {}),
    endpoints: { chatCompletions: { enabled: true }, responses: { enabled: true } },
  },
};
cfg.channels = {
  ...(cfg.channels && typeof cfg.channels === 'object' ? cfg.channels : {}),
  slack: {
    ...(cfg.channels && cfg.channels.slack && typeof cfg.channels.slack === 'object'
      ? cfg.channels.slack
      : {}),
    enabled: true,
    dmPolicy: 'open',
    groupPolicy: 'open',
    allowFrom: parseJsonEnv('OPENCLAW_SLACK_ALLOWED_MEMBERS', ['*']),
  },
};
cfg.tools = {
  ...(cfg.tools && typeof cfg.tools === 'object' ? cfg.tools : {}),
  profile: 'full',
  // Managed web_search for DeepSeek (and other non-OpenAI) models. Gemini uses the
  // existing GEMINI_API_KEY env; auto-detect can miss it if a stale provider pin remains.
  web: {
    ...(cfg.tools && cfg.tools.web && typeof cfg.tools.web === 'object' ? cfg.tools.web : {}),
    search: {
      ...(cfg.tools &&
      cfg.tools.web &&
      cfg.tools.web.search &&
      typeof cfg.tools.web.search === 'object'
        ? cfg.tools.web.search
        : {}),
      enabled: true,
      provider: 'gemini',
    },
  },
};
// Memory embeddings default to OpenAI; pin Gemini so session-delta sync does not burn
// OPENAI_API_KEY credits (chat already uses DeepSeek).
cfg.memory = {
  ...(cfg.memory && typeof cfg.memory === 'object' ? cfg.memory : {}),
  search: {
    ...(cfg.memory && cfg.memory.search && typeof cfg.memory.search === 'object'
      ? cfg.memory.search
      : {}),
    provider: 'gemini',
  },
};
cfg.agents = cfg.agents && typeof cfg.agents === 'object' ? cfg.agents : {};
cfg.agents.defaults = {
  ...(cfg.agents.defaults && typeof cfg.agents.defaults === 'object' ? cfg.agents.defaults : {}),
  model: { primary: 'deepseek/deepseek-v4-pro' },
  heartbeat: {
    model: 'deepseek/deepseek-v4-flash',
    isolatedSession: true,
    lightContext: true,
    every: '12h',
    target: 'slack',
  },
};
cfg.agents.entries = {
  planner: {
    default: true,
    workspace: '/home/node/.openclaw/workspace-planner',
    model: { primary: 'deepseek/deepseek-v4-pro' },
    thinkingDefault: 'high',
    subagents: { allowAgents: ['executor'] },
  },
  executor: {
    workspace: '/home/node/.openclaw/workspace-executor',
    model: { primary: 'deepseek/deepseek-v4-pro' },
    thinkingDefault: 'adaptive',
  },
};
delete cfg.agents.list;
// This template owns the MCP server map outright. openclaw.json persists on the file share,
// so spreading the existing map would resurrect servers retired from the deployment.
cfg.mcp = {
  ...(cfg.mcp && typeof cfg.mcp === 'object' ? cfg.mcp : {}),
  servers: {
    // Financial GraphRAG gateway (ACA fingraphrag-pilotus-mcp, rg fingraphrag-pilotus-rg).
    // Streamable HTTP at /mcp with SSE-framed responses; stateless, no auth header required.
    fingraphrag: {
      url: 'https://fingraphrag-pilotus-mcp.nicesea-bfeec3ce.eastus.azurecontainerapps.io/mcp',
      transport: 'streamable-http',
    },
  },
};
cfg.models = cfg.models && typeof cfg.models === 'object' ? cfg.models : {};
cfg.models.providers = {
  ...(cfg.models.providers && typeof cfg.models.providers === 'object' ? cfg.models.providers : {}),
  'azure-openai-responses': {
    api: 'openai-responses',
    models: [{ id: 'gpt-4o', name: 'GPT-4o' }],
    baseUrl: process.env.AZURE_OPENAI_BASE_URL || '',
    apiKey: process.env.AZURE_OPENAI_API_KEY || '',
  },
};
cfg.plugins = cfg.plugins && typeof cfg.plugins === 'object' ? cfg.plugins : {};
delete cfg.plugins.allow;
cfg.plugins.entries = {
  ...(cfg.plugins.entries && typeof cfg.plugins.entries === 'object' ? cfg.plugins.entries : {}),
  // Keep Google loaded so the gemini web_search provider registers at gateway startup.
  google: {
    ...(cfg.plugins.entries &&
    cfg.plugins.entries.google &&
    typeof cfg.plugins.entries.google === 'object'
      ? cfg.plugins.entries.google
      : {}),
    enabled: true,
  },
};
if (fs.existsSync('/app/custom-plugins/token-budget')) {
  cfg.plugins.load = { paths: ['/app/custom-plugins/token-budget'] };
  cfg.plugins.entries['token-budget'] = {
    enabled: true,
    config: {
      monthlyLimit: 5000000,
      warningThreshold: 0.9,
      fallbackProvider: 'azure-openai-responses',
      fallbackModel: 'gpt-4o',
    },
  };
} else {
  if (cfg.plugins.load) {
    delete cfg.plugins.load.paths;
    if (Object.keys(cfg.plugins.load).length === 0) delete cfg.plugins.load;
  }
  delete cfg.plugins.entries['token-budget'];
}
fs.writeFileSync(configPath, `${JSON.stringify(cfg, null, 2)}\n`);
EOF
export NODE_OPTIONS="--require /tmp/patch.js"
set -e
# Azure Files (CIFS) deadlocks SQLite, and doctor refuses session SQLite import through any
# symbolic-link path component. So do not symlink DBs: put the whole runtime state tree on
# local disk via OPENCLAW_STATE_DIR, and keep only config + workspaces on the file share via
# OPENCLAW_CONFIG_PATH. Credentials are re-seeded each boot; sessions/cron/pairings reset.
export OPENCLAW_STATE_DIR=/tmp/openclaw-runtime
export OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json
mkdir -p "$OPENCLAW_STATE_DIR/state" "$OPENCLAW_STATE_DIR/agents"
# Tear down leftover share-side SQLite symlinks from earlier revisions that doctor now rejects.
if [ -L /home/node/.openclaw/state ]; then
  rm -f /home/node/.openclaw/state
fi
for agent_dir in /home/node/.openclaw/agents/*/agent; do
  [ -d "$agent_dir" ] || continue
  for f in openclaw-agent.sqlite openclaw-agent.sqlite-wal openclaw-agent.sqlite-shm; do
    if [ -L "$agent_dir/$f" ]; then
      rm -f "$agent_dir/$f"
    fi
  done
done
# Retired credential files are detected by NAME ONLY and hard-fail every auth load with
# AuthProfileMigrationRequiredError. Clear share leftovers and any copies under STATE_DIR.
# Keys are re-seeded from env into SQLite below, so deleting them loses nothing.
rm -f /home/node/.openclaw/agents/*/agent/auth-profiles.json \
      /home/node/.openclaw/agents/*/agent/auth.json \
      /home/node/.openclaw/agents/*/agent/auth-state.json \
      "$OPENCLAW_STATE_DIR"/agents/*/agent/auth-profiles.json \
      "$OPENCLAW_STATE_DIR"/agents/*/agent/auth.json \
      "$OPENCLAW_STATE_DIR"/agents/*/agent/auth-state.json
mkdir -p /home/node/.openclaw/workspace
# Repair + apply the full desired config in one Node write (see /tmp/repair-config.js).
# Do NOT interleave dozens of `openclaw config set` calls: each boots Node + reloads MCP
# (~6s), and ACA recycles the replica before `exec gateway` ever runs.
node /tmp/repair-config.js
cat << 'AGENTS_EOF' > /home/node/.openclaw/workspace/AGENTS.md
# Agent Instructions

You are a helpful enterprise assistant.

## CITATION & FORMATTING RULES
When you call `web_search`, the tool result JSON contains a `citations` array with `url` and `title` fields, AND the content text ends with a numbered "References:" section. You MUST use these URLs as clickable links in your response. NEVER omit them.

**How to format links (check the Runtime channel= line in your system prompt):**
* If channel is **slack**: Use Slack link syntax exactly: `<URL|[1]>` — e.g. `<https://example.com|[1]>`
* If channel is **wecom**: Use Markdown link syntax: `[[1]](URL)`
* For **all other channels**: Use standard Markdown: `[1](URL)`

**Rules:**
1. Every factual claim from web_search MUST have at least one citation link.
2. Place citation links inline at the end of the relevant sentence or paragraph.
3. Prefer URLs from the `citations` array (they are resolved/clean URLs).
4. If `citations` is empty, use URLs from the References section in the content.

## MCP
Follow skill `asireon-mcp`: for SEC filing / financial statement questions (10-K, 10-Q, XBRL metrics), use the `fingraphrag` MCP tools and report figures exactly as filed with their citations.
AGENTS_EOF
# Pre-create SOUL.md and USER.md so the personal-assistant templates are not scaffolded.
cat << 'SOUL_EOF' > /home/node/.openclaw/workspace/SOUL.md
# Enterprise Assistant
Helpful, concise, and citation-accurate. No persona or personal relationship framing.
SOUL_EOF
cat << 'USER_EOF' > /home/node/.openclaw/workspace/USER.md
# Shared Enterprise Workspace
Multi-user deployment — no single user profile.
USER_EOF
# Pre-create BOOTSTRAP.md (empty) so the onboarding wizard is not injected into context.
touch /home/node/.openclaw/workspace/BOOTSTRAP.md
# Activate memory curation: add a non-empty task to HEARTBEAT.md so the LLM call runs.
# Without this, the heartbeat runner fires every 30m but skips the API call because the
# default template is all markdown headers (treated as comments by isHeartbeatContentEffectivelyEmpty).
cat << 'HEARTBEAT_EOF' > /home/node/.openclaw/workspace/HEARTBEAT.md
# Periodic memory curation
- Check the memory/ directory for date-stamped files (memory/YYYY-MM-DD.md) written since last curation.
- If new entries exist, distill key facts, decisions, and patterns into MEMORY.md (create if absent).
- Keep MEMORY.md concise: facts and decisions only, no raw transcript. Append; never overwrite existing entries.
- If nothing new to curate, reply HEARTBEAT_OK.
HEARTBEAT_EOF
# Install deployment skill from the image when present (source: deploy/skills/asireon-mcp/SKILL.md).
# Azure Files rejects cp -a timestamp preserve ("Operation not permitted"); copy content only.
SKILL_SRC=/app/deploy/skills/asireon-mcp
if [ -f "$SKILL_SRC/SKILL.md" ]; then
  for dest in \
    /home/node/.openclaw/skills/asireon-mcp \
    /home/node/.openclaw/workspace/skills/asireon-mcp \
    /home/node/.openclaw/workspace-planner/skills/asireon-mcp \
    /home/node/.openclaw/workspace-executor/skills/asireon-mcp
  do
    mkdir -p "$dest"
    cp "$SKILL_SRC/SKILL.md" "$dest/SKILL.md"
  done
fi
mkdir -p /home/node/.openclaw/workspace-planner
touch /home/node/.openclaw/workspace-planner/BOOTSTRAP.md
cat << 'PLANNER_EOF' > /home/node/.openclaw/workspace-planner/AGENTS.md
# Planner Agent

You receive user tasks and produce a complete, actionable plan before any execution begins.

## Responsibilities
- Analyse the request thoroughly using extended thinking.
- Decompose the work into numbered, self-contained steps.
- Once the plan is finalised, delegate ALL execution to the executor agent via `sessions_spawn`.

## MCP (see skill `asireon-mcp`)
- For SEC filing / financial statement requests, plan around the `fingraphrag` MCP tools and name the entities, periods, and metrics the executor should query.

## Handoff rule (mandatory)
When you have a complete plan, call `sessions_spawn` exactly once:
- `agentId`: "executor"
- `task`: the full plan as a structured prompt (include all context the executor will need, including the entities, periods, and metrics to query)
- Do NOT attempt to execute any step yourself.

After sessions_spawn returns, summarise the executor's result for the user.
PLANNER_EOF
mkdir -p /home/node/.openclaw/workspace-executor
touch /home/node/.openclaw/workspace-executor/BOOTSTRAP.md
cat << 'EXECUTOR_EOF' > /home/node/.openclaw/workspace-executor/AGENTS.md
# Executor Agent

You receive a fully-formed plan from the planner agent and carry it out step by step.

## Responsibilities
- Execute each step of the plan completely and concisely.
- Do not re-plan or ask clarifying questions — the plan is final.
- Use available tools (web_search, fingraphrag, bash, etc.) as needed.
- For SEC filing / financial statement data, use the `fingraphrag` MCP tools and keep the filed figures and citations they return.
- Return a structured summary of what was done and any outputs or artefacts produced.

## MCP (see skill `asireon-mcp`)
- `fingraphrag` tools: max 2 retries per call, transient errors only; on failure, report the last error — never substitute numbers from memory.
EXECUTOR_EOF
rm -rf /home/node/.openclaw/extensions/token-budget
# One doctor pass only — it connects every configured MCP server.
node openclaw.mjs doctor --non-interactive --fix --yes
# Seed only the keys each agent actually needs. paste-api-key also boots a full CLI.
seed_credential() {
  agent_id="$1"
  provider="$2"
  key="$3"
  if [ -z "$key" ]; then
    return 0
  fi
  if ! printf '%s' "$key" | node openclaw.mjs models auth --agent "$agent_id" paste-api-key \
    --provider "$provider" --profile-id "$provider:default" >/dev/null; then
    echo "WARN: failed to seed $provider credentials for agent $agent_id" >&2
  fi
}
seed_credential planner deepseek "$DEEPSEEK_API_KEY"
seed_credential planner google "$GEMINI_API_KEY"
seed_credential executor deepseek "$DEEPSEEK_API_KEY"
# OpenAI key stays seeded for availability; executor primary model is DeepSeek.
seed_credential executor openai "$OPENAI_API_KEY"
# Re-assert after doctor (it rewrites the config file).
node /tmp/repair-config.js
exec node openclaw.mjs gateway --bind lan
            '''
          ]
          env: [
            // Core Security
            // Must be OPENCLAW_GATEWAY_TOKEN: the gateway credential planner reads only that
            // name, so any other spelling leaves the gateway unauthenticated behind ingress.
            {
              name: 'OPENCLAW_GATEWAY_TOKEN'
              secretRef: 'gateway-token'
            }
            // Split runtime state (local ephemeral disk) from config/workspaces (Azure Files).
            // Symlinking SQLite files is rejected by doctor session import.
            {
              name: 'OPENCLAW_STATE_DIR'
              value: '/tmp/openclaw-runtime'
            }
            {
              name: 'OPENCLAW_CONFIG_PATH'
              value: '/home/node/.openclaw/openclaw.json'
            }

            // Slack Integration
            {
              name: 'SLACK_BOT_TOKEN'
              secretRef: 'slack-bot-token'
            }
            {
              name: 'SLACK_APP_TOKEN'
              secretRef: 'slack-app-token'
            }

            // LLM API Keys
            {
              name: 'OPENAI_API_KEY'
              secretRef: 'openai-api-key'
            }
            {
              name: 'ANTHROPIC_API_KEY'
              secretRef: 'anthropic-api-key'
            }
            {
              name: 'GEMINI_API_KEY'
              secretRef: 'gemini-api-key'
            }
            {
              name: 'DEEPSEEK_API_KEY'
              secretRef: 'deepseek-api-key'
            }

            // The two variables below are read by the startup script as shell inputs to
            // `config set`, not by OpenClaw itself. Apart from OPENCLAW_GATEWAY_TOKEN there is
            // no generic OPENCLAW_*-to-config override, so env vars named after config paths
            // (model routing, Control UI auth) are silently ignored and must go through config.

            // UI Origin Configuration
            {
              name: 'OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS'
              // Dynamically whitelist the Azure Container App's own default hostname
              value: 'https://${containerAppName}.${containerAppEnv.properties.defaultDomain}'
            }

            // Slack Access Control
            {
              name: 'OPENCLAW_SLACK_ALLOWED_MEMBERS'
              value: slackAllowedMembers
            }

            // Azure OpenAI (Token Budget Fallback — provisioned by this template)
            {
              name: 'AZURE_OPENAI_API_KEY'
              secretRef: 'azure-openai-api-key'
            }
            {
              name: 'AZURE_OPENAI_BASE_URL'
              value: openAiAccount.properties.endpoint
            }
          ]
          volumeMounts: [
            {
              volumeName: 'openclaw-volume'
              mountPath: '/home/node/.openclaw'
            }
          ]
          // Container Apps requires memory to be exactly 2Gi per vCPU. The gateway alone sits
          // near 1Gi, and `openclaw exec`/CLI sessions fork a second full Node process, so 2Gi
          // total left no headroom and the shell was SIGKILLed (exit 137).
          resources: {
            cpu: json('2.0')
            memory: '4Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}
