---
name: asireon-mcp
description: "Enterprise MCP workflow: rag-search every user request for RAG instructions; asireon-function-call retry limits and stick-to-specified-endpoint rules; fingraphrag for SEC filing financials."
metadata: { "openclaw": { "emoji": "📚", "always": true } }
---

# Asireon MCP + RAG

Mandatory workflow for this deployment's MCP servers `rag-search`, `asireon-function-call`, and `fingraphrag`.

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

## fingraphrag — SEC filing financials

Use MCP server `fingraphrag` (Financial GraphRAG) for any question about a company's reported financials: 10-K / 10-Q figures, XBRL metrics, financial statements, filing text, metric history, or drivers. It still runs **after** `rag-search`; org RAG guidance wins on process, `fingraphrag` wins on filed numbers.

Tools: `get_financial_metric`, `get_metric_history`, `get_financial_statement`, `search_filings`, `read_document_section`, `get_evidence_by_id`, `trace_financial_relationship`, `get_metric_drivers`, `resolve_financial_claim`, `get_adjustment_inputs`, `get_reporting_profile`.

Rules:

1. **Reported numbers only.** Tools return figures exactly as filed, with citations. Every number you state must come from a tool result and keep its citation (filing + release date). Never estimate or fill a gap from memory.
2. **Arithmetic is yours.** Deltas, ratios, bridges, derived quarters, and adjustments are not computed server-side — compute them from filed rows and show the inputs.
3. **Entities and periods.** `entity_id` accepts a ticker, company name, or CIK (resolved server-side). Periods: `FY2024` (annual), `2024-Q2` (fiscal quarter), an ISO date, or a calendar span like `3M ending 2024-06-30`. Metric aliases such as `revenue` or `operating cash flow` resolve server-side.
4. **Gaps are explicit.** A period no filing reports (a discrete Q4, a 3-month cash flow) comes back as a gap listing the adjacent reported spans — subtract those yourself and say you derived it. Do not retry other tools to "find" a number the filings do not contain.
5. **Precision and restatements.** Rows carry XBRL decimals precision and the assertion chain across filings; when a value was restated, report the latest assertion and note the restatement. Use `as_of_date` when the user asks what was known at a point in time.
6. Retry budget is the same as `asireon-function-call`: 2 retries, transient errors only.
