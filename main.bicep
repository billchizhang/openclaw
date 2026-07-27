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
  // Drop the stale token-budget entry when the plugin is not actually in the image.
  if (
    cfg.plugins.entries &&
    typeof cfg.plugins.entries === 'object' &&
    cfg.plugins.entries['token-budget'] &&
    !fs.existsSync('/app/custom-plugins/token-budget')
  ) {
    delete cfg.plugins.entries['token-budget'];
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
fs.writeFileSync(configPath, `${JSON.stringify(cfg, null, 2)}\n`);
EOF
export NODE_OPTIONS="--require /tmp/patch.js"
set -e
# Azure Files (CIFS) still returns "database is locked" under OpenClaw even with rollback
# journaling — confirmed in production logs for plugin state + doctor migrations. Keep runtime
# SQLite on local ephemeral disk; re-seed credentials each boot; accept that sessions/cron/pairings
# reset on restart until a non-SMB volume is available.
LOCAL_RUNTIME=/tmp/openclaw-runtime
mkdir -p "$LOCAL_RUNTIME/state"
if [ -d /home/node/.openclaw/state ] && [ ! -L /home/node/.openclaw/state ]; then
  # Prefer a fresh local DB over a share-backed one that already deadlocks under load.
  rm -rf /home/node/.openclaw/state
fi
ln -sfn "$LOCAL_RUNTIME/state" /home/node/.openclaw/state
link_agent_sqlite_local() {
  agent_id="$1"
  agent_dir="/home/node/.openclaw/agents/$agent_id/agent"
  local_dir="$LOCAL_RUNTIME/agents/$agent_id/agent"
  mkdir -p "$local_dir" "$agent_dir"
  for f in openclaw-agent.sqlite openclaw-agent.sqlite-wal openclaw-agent.sqlite-shm; do
    if [ -e "$agent_dir/$f" ] && [ ! -L "$agent_dir/$f" ]; then
      rm -f "$agent_dir/$f"
    fi
    if [ ! -e "$agent_dir/$f" ]; then
      ln -sfn "$local_dir/$f" "$agent_dir/$f"
    fi
  done
}
for agent_id in main planner executor; do
  link_agent_sqlite_local "$agent_id"
done
# Retired credential files are detected by NAME ONLY and hard-fail every auth load with
# AuthProfileMigrationRequiredError, even when the SQLite store is healthy. Doctor itself loads
# auth during its checks, so these must be gone before the first doctor run, not after. Keys are
# re-seeded from env into SQLite below, so deleting them loses nothing.
rm -f /home/node/.openclaw/agents/*/agent/auth-profiles.json \
      /home/node/.openclaw/agents/*/agent/auth.json \
      /home/node/.openclaw/agents/*/agent/auth-state.json
mkdir -p /home/node/.openclaw/workspace
# Strip known-dead keys from the persisted Azure File Share config BEFORE any config set.
# `config set` refuses invalid config, so a stale token-budget path or Slack streaming alias
# leaves gateway.mode unset and the gateway blocked.
node /tmp/repair-config.js
node openclaw.mjs doctor --non-interactive --fix --yes
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
node openclaw.mjs config set gateway.mode '"local"'
node openclaw.mjs config set gateway.bind '"lan"'
node openclaw.mjs config set agents.defaults.heartbeat.model '"deepseek/deepseek-v4-flash"'
node openclaw.mjs config set agents.defaults.heartbeat.isolatedSession true
node openclaw.mjs config set agents.defaults.heartbeat.lightContext true
node openclaw.mjs config set agents.defaults.heartbeat.every '"12h"'
node openclaw.mjs config set agents.defaults.heartbeat.target '"slack"'
node openclaw.mjs config set gateway.trustedProxies '["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]'
node openclaw.mjs config set gateway.controlUi.allowedOrigins "[\"$OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS\"]"
node openclaw.mjs config set channels.slack.enabled true
node openclaw.mjs config set channels.slack.dmPolicy '"open"'
node openclaw.mjs config set channels.slack.allowFrom "$OPENCLAW_SLACK_ALLOWED_MEMBERS"
node openclaw.mjs config set channels.slack.groupPolicy '"open"'
node openclaw.mjs config set tools.profile full
node openclaw.mjs mcp set rag-search '{"url":"https://retrieval-mcp-server.internal.lemonforest-578b1773.eastus.azurecontainerapps.io/mcp","transport":"streamable-http"}'
node openclaw.mjs mcp set asireon-function-call '{"url":"https://asireon-func-mcp.internal.lemonforest-578b1773.eastus.azurecontainerapps.io/mcp","transport":"streamable-http"}'
node openclaw.mjs config set agents.defaults.model.primary '"deepseek/deepseek-v4-pro"'
node openclaw.mjs config set 'agents.entries.planner' '{"default":true,"workspace":"/home/node/.openclaw/workspace-planner","model":{"primary":"deepseek/deepseek-v4-pro"},"thinkingDefault":"high","subagents":{"allowAgents":["executor"]}}'
node openclaw.mjs config unset 'agents.entries.planner.model.fallback'
node openclaw.mjs config unset 'agents.entries.planner.model.fallbacks'
node openclaw.mjs config unset agents.list
node openclaw.mjs config set 'agents.entries.executor' '{"workspace":"/home/node/.openclaw/workspace-executor","model":{"primary":"openai/gpt-5.4-mini"},"thinkingDefault":"adaptive"}'
# Seed API keys straight into each agent's SQLite auth store. paste-api-key reads the secret from
# piped stdin when stdin is not a TTY, so no key is ever passed as an argument or written to disk.
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
seed_agent_credentials() {
  seed_credential "$1" deepseek "$DEEPSEEK_API_KEY"
  seed_credential "$1" openai "$OPENAI_API_KEY"
  seed_credential "$1" anthropic "$ANTHROPIC_API_KEY"
  seed_credential "$1" google "$GEMINI_API_KEY"
}
mkdir -p /home/node/.openclaw/workspace-planner
touch /home/node/.openclaw/workspace-planner/BOOTSTRAP.md
cat << 'PLANNER_EOF' > /home/node/.openclaw/workspace-planner/AGENTS.md
# Planner Agent

You receive user tasks and produce a complete, actionable plan before any execution begins.

## Responsibilities
- Analyse the request thoroughly using extended thinking.
- Decompose the work into numbered, self-contained steps.
- Once the plan is finalised, delegate ALL execution to the executor agent via `sessions_spawn`.

## Handoff rule (mandatory)
When you have a complete plan, call `sessions_spawn` exactly once:
- `agentId`: "executor"
- `task`: the full plan as a structured prompt (include all context the executor will need)
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
- Use available tools (web_search, rag-search, asireon-function-call, bash, etc.) as needed.
- Return a structured summary of what was done and any outputs or artefacts produced.
EXECUTOR_EOF
# Clear any stale plugins.allow allowlist that may persist on the Azure File Share from prior deployments.
# An allowlist with only "token-budget" would silently block all other bundled channel plugins (including Slack).
node openclaw.mjs config unset plugins.allow
# whatsapp is an external plugin that was never installed here; the stale entry only emits a warning.
node openclaw.mjs config unset plugins.entries.whatsapp
# Azure OpenAI provider for token budget fallback (must be configured before plugin refs it).
# models[] entries are objects; a bare ["gpt-4o"] string array fails schema validation.
node openclaw.mjs config set models.providers.azure-openai-responses.api '"openai-responses"'
node openclaw.mjs config set models.providers.azure-openai-responses.models '[{"id":"gpt-4o","name":"GPT-4o"}]'
node openclaw.mjs config set models.providers.azure-openai-responses.baseUrl "$AZURE_OPENAI_BASE_URL"
node openclaw.mjs config set models.providers.azure-openai-responses.apiKey "$AZURE_OPENAI_API_KEY"
# ── Token Budget Plugin ──────────────────────────────────────────
# A missing plugins.load.paths entry is a hard config validation error, and an invalid config
# cascades: plugin discovery aborts, channel doctor contracts never run their legacy migrations,
# and gateway.mode reads as unset. Only register the path once the plugin is really in the image.
rm -rf /home/node/.openclaw/extensions/token-budget
if [ -d /app/custom-plugins/token-budget ]; then
  node openclaw.mjs config set plugins.load.paths '["/app/custom-plugins/token-budget"]'
  node openclaw.mjs config set plugins.entries.token-budget.enabled true
  node openclaw.mjs config set plugins.entries.token-budget.config.monthlyLimit 5000000
  node openclaw.mjs config set plugins.entries.token-budget.config.warningThreshold 0.9
  # Fall back to the Azure OpenAI deployment provisioned by this template. The provider carries an
  # explicit apiKey above, so embedded agents do not depend on env-var credential discovery.
  node openclaw.mjs config set plugins.entries.token-budget.config.fallbackProvider '"azure-openai-responses"'
  node openclaw.mjs config set plugins.entries.token-budget.config.fallbackModel '"gpt-4o"'
else
  echo "WARN: /app/custom-plugins/token-budget missing; clearing stale token-budget config." >&2
  # Both the path and the entry invalidate config / emit stale-entry warnings. Clear both.
  node openclaw.mjs config unset plugins.load.paths
  node openclaw.mjs config unset plugins.entries.token-budget
fi
node /tmp/repair-config.js
node openclaw.mjs doctor --non-interactive --fix --yes
# Must run after doctor: a leftover legacy credential file makes every auth-store write fail.
# Agent SQLite stores are on ephemeral local disk, so they start empty on each boot.
for agent_id in main planner executor; do
  seed_agent_credentials "$agent_id"
done
# Re-assert last: the gateway start guard refuses to boot without gateway.mode, and doctor
# rewrites the whole config file after every repair pass.
node openclaw.mjs config set gateway.mode '"local"'
node openclaw.mjs config set gateway.bind '"lan"'
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
