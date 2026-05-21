import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";
import {
  createWebSearchProviderContractFields,
  mergeScopedSearchConfig,
  resolveProviderWebSearchPluginConfig,
  type WebSearchProviderPlugin,
  type WebSearchProviderToolDefinition,
} from "openclaw/plugin-sdk/provider-web-search-config-contract";
import {
  resolveGeminiApiKey,
  resolveGeminiBaseUrl,
  resolveGeminiModel,
} from "./gemini-web-search-provider.shared.js";

const GEMINI_CREDENTIAL_PATH = "plugins.entries.google.config.webSearch.apiKey";
const GOOGLE_PROVIDER_CREDENTIAL_PATH = "models.providers.google.apiKey";

type GeminiWebSearchRuntime = typeof import("./gemini-web-search-provider.runtime.js");

type GeminiGroundingResponse = {
  candidates?: Array<{
    content?: {
      parts?: Array<{
        text?: string;
      }>;
    };
    groundingMetadata?: {
      groundingChunks?: Array<{
        web?: {
          uri?: string;
          title?: string;
        };
      }>;
      groundingSupports?: Array<{
        segment?: { startIndex?: number; endIndex?: number; text?: string };
        groundingChunkIndices?: number[];
      }>;
      searchEntryPoint?: {
        renderedContent?: string;
      };
      webSearchQueries?: string[];
    };
  }>;
  error?: {
    code?: number;
    message?: string;
    status?: string;
  };
};

let geminiWebSearchRuntimePromise: Promise<GeminiWebSearchRuntime> | undefined;


function loadGeminiWebSearchRuntime(): Promise<GeminiWebSearchRuntime> {
  geminiWebSearchRuntimePromise ??= import("./gemini-web-search-provider.runtime.js");
  return geminiWebSearchRuntimePromise;
}

function resolveGeminiApiKey(gemini?: GeminiConfig): string | undefined {
  return (
    readConfiguredSecretString(gemini?.apiKey, "tools.web.search.gemini.apiKey") ??
    readProviderEnvValue(["GEMINI_API_KEY"])
  );
}

function resolveGeminiModel(gemini?: GeminiConfig): string {
  const model = typeof gemini?.model === "string" ? gemini.model.trim() : "";
  return model || DEFAULT_GEMINI_MODEL;
}

async function runGeminiSearch(params: {
  query: string;
  apiKey: string;
  model: string;
  timeoutSeconds: number;
}): Promise<{ content: string; citations: Array<{ url: string; title?: string }> }> {
  const endpoint = `${GEMINI_API_BASE}/models/${params.model}:generateContent`;

  return withTrustedWebSearchEndpoint(
    {
      url: endpoint,
      timeoutSeconds: params.timeoutSeconds,
      init: {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": params.apiKey,
        },
        body: JSON.stringify({
          contents: [{ parts: [{ text: params.query }] }],
          tools: [{ google_search: {} }],
          generationConfig: {
            maxOutputTokens: 16364,
          },
        }),
      },
    },
    async (res) => {
      if (!res.ok) {
        const safeDetail = ((await res.text()) || res.statusText).replace(
          /key=[^&\s]+/gi,
          "key=***",
        );
        throw new Error(`Gemini API error (${res.status}): ${safeDetail}`);
      }

      let data: GeminiGroundingResponse;
      try {
        data = (await res.json()) as GeminiGroundingResponse;
      } catch (error) {
        const safeError = String(error).replace(/key=[^&\s]+/gi, "key=***");
        throw new Error(`Gemini API returned invalid JSON: ${safeError}`, { cause: error });
      }

      if (data.error) {
        const rawMessage = data.error.message || data.error.status || "unknown";
        throw new Error(
          `Gemini API error (${data.error.code}): ${rawMessage.replace(/key=[^&\s]+/gi, "key=***")}`,
        );
      }

      const candidate = data.candidates?.[0];
      let content =
        candidate?.content?.parts
          ?.map((part) => part.text)
          .filter(Boolean)
          .join("\n") ?? "No response";
      const rawCitations = (candidate?.groundingMetadata?.groundingChunks ?? [])
        .filter((chunk) => chunk.web?.uri)
        .map((chunk) => ({
          url: chunk.web!.uri!,
          title: chunk.web?.title || undefined,
        }));

      const citations: Array<{ url: string; title?: string }> = [];
      for (let index = 0; index < rawCitations.length; index += 10) {
        const batch = rawCitations.slice(index, index + 10);
        const resolved = await Promise.all(
          batch.map(async (citation) => ({
            ...citation,
            url: await resolveCitationRedirectUrl(citation.url),
          })),
        );
        citations.push(...resolved);
      }

      // Append a References footer so the LLM sees citation URLs inline in the content.
      if (citations.length > 0) {
        const refsLines = citations.map(
          (c, i) => `[${i + 1}] ${c.title ? `${c.title}: ` : ""}${c.url}`,
        );
        content = `${content}\n\nReferences:\n${refsLines.join("\n")}`;
      }

      return { content, citations };
    },
  );
}

const GEMINI_TOOL_PARAMETERS = {
  type: "object",
  properties: {
    query: { type: "string", description: "Search query string." },
    count: {
      type: "number",
      description: "Number of results to return (1-10).",
      minimum: 1,
      maximum: 10,
    },
    country: { type: "string", description: "Not supported by Gemini." },
    language: { type: "string", description: "Not supported by Gemini." },
    freshness: {
      type: "string",
      description: "Limit Google Search grounding to recent results: day, week, month, or year.",
    },
    date_after: {
      type: "string",
      description: "Only ground with results published after this date (YYYY-MM-DD).",
    },
    date_before: {
      type: "string",
      description: "Only ground with results published before this date (YYYY-MM-DD).",
    },
  },
  required: ["query"],
} satisfies Record<string, unknown>;

function createGeminiToolDefinition(
  searchConfig?: Record<string, unknown>,
): WebSearchProviderToolDefinition {
  return {
    description:
      "Search the web using Gemini with Google Search grounding. Returns AI-synthesized answers with citations from Google Search.",
    parameters: GEMINI_TOOL_PARAMETERS,
    execute: async (args, context) => {
      const { executeGeminiSearch } = await loadGeminiWebSearchRuntime();
      return await executeGeminiSearch(args, searchConfig, context);
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function resolveGoogleModelProviderConfig(
  config?: OpenClawConfig,
): Record<string, unknown> | undefined {
  const provider = config?.models?.providers?.google;
  return isRecord(provider) ? provider : undefined;
}

function getGoogleModelProviderCredentialFallback(
  config?: OpenClawConfig,
): { path: string; value: unknown } | undefined {
  const provider = resolveGoogleModelProviderConfig(config);
  return provider && provider.apiKey !== undefined
    ? { path: GOOGLE_PROVIDER_CREDENTIAL_PATH, value: provider.apiKey }
    : undefined;
}

function withGoogleModelProviderFallbacks(
  searchConfig: Record<string, unknown> | undefined,
  config?: OpenClawConfig,
): Record<string, unknown> | undefined {
  const provider = resolveGoogleModelProviderConfig(config);
  if (!provider || (provider.apiKey === undefined && provider.baseUrl === undefined)) {
    return searchConfig;
  }
  const gemini = isRecord(searchConfig?.gemini) ? { ...searchConfig.gemini } : {};
  const mergedSearchConfig = searchConfig ? { ...searchConfig } : {};
  if (provider.apiKey !== undefined) {
    gemini.providerApiKey = provider.apiKey;
  }
  if (provider.baseUrl !== undefined) {
    gemini.providerBaseUrl = provider.baseUrl;
  }
  return {
    ...mergedSearchConfig,
    gemini,
  };
}

export function createGeminiWebSearchProvider(): WebSearchProviderPlugin {
  const contractFields = createWebSearchProviderContractFields({
    credentialPath: GEMINI_CREDENTIAL_PATH,
    searchCredential: { type: "scoped", scopeId: "gemini" },
    configuredCredential: { pluginId: "google" },
  });

  return {
    id: "gemini",
    label: "Gemini (Google Search)",
    hint: "Requires Google Gemini API key · Google Search grounding",
    onboardingScopes: ["text-inference"],
    credentialLabel: "Google Gemini API key",
    envVars: ["GEMINI_API_KEY"],
    placeholder: "AIza...",
    signupUrl: "https://aistudio.google.com/apikey",
    docsUrl: "https://docs.openclaw.ai/tools/web",
    autoDetectOrder: 20,
    credentialPath: GEMINI_CREDENTIAL_PATH,
    ...contractFields,
    getConfiguredCredentialFallback: getGoogleModelProviderCredentialFallback,
    createTool: (ctx) =>
      createGeminiToolDefinition(
        withGoogleModelProviderFallbacks(
          mergeScopedSearchConfig(
            ctx.searchConfig,
            "gemini",
            resolveProviderWebSearchPluginConfig(ctx.config, "google"),
          ),
          ctx.config,
        ),
      ),
  };
}

export const testing = {
  resolveGeminiApiKey,
  resolveGeminiBaseUrl,
  resolveGeminiModel,
} as const;
export { testing as __testing };
