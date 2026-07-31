---
name: asireon-mcp
description: "Enterprise MCP workflow: rag-search every user request for RAG instructions; asireon-function-call retry limits and stick-to-specified-endpoint rules."
metadata:
  {
    "openclaw":
      {
        "emoji": "📚",
        "always": true,
      },
  }
---

# Asireon MCP + RAG

Mandatory workflow for this deployment's MCP servers `rag-search` and `asireon-function-call`.

## Every user request — rag-search first

1. Before planning or acting, call the MCP `rag-search` server with the user's request (and any clarifying context).
2. Treat returned hits as authoritative instructions/docs for this org when relevant.
3. Prefer RAG guidance over guessing endpoints, parameters, or business process.
4. If RAG returns nothing useful, say so briefly and continue with best effort — do not invent org-specific endpoints.
5. Re-query `rag-search` when the task pivots to a new domain or the user names a different system/endpoint.

## asireon-function-call — retries

When calling tools on MCP server `asireon-function-call`:

- Cap retries for the **same** failed endpoint/action at **2 retries** (3 attempts total).
- Retry only for clearly transient failures (timeouts, 429, 502/503/504).
- Do **not** retry auth/permission/validation/not-found errors in a loop.
- After the retry budget is exhausted, stop that action and report the failure with the endpoint/action and last error.

## asireon-function-call — stick to the specified endpoint

When the user (directly) or RAG docs (explicitly) name a specific endpoint/action/path to use:

1. Call **only** that endpoint/action.
2. On failure, apply the retry budget above against **that same** endpoint/action only.
3. Do **not** bypass, substitute, or "helpfully" try other endpoints/actions/tools to get a success.
4. If it still fails after retries, report failure and wait for user direction — never silently fall through to alternatives.

Unspecified requests may choose a fitting asireon tool from RAG or available tools. Once a specific endpoint is chosen from explicit user/RAG instruction, it is locked for that step.
