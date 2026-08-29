---
name: asireon-mcp
description: "Enterprise MCP workflow: fingraphrag for SEC filing financials — reported numbers only, citations, explicit gaps, retry limits."
metadata: { "openclaw": { "emoji": "📚", "always": true } }
---

# Asireon MCP

Mandatory workflow for this deployment's MCP server `fingraphrag`.

## fingraphrag — SEC filing financials

Use MCP server `fingraphrag` (Financial GraphRAG) for any question about a company's reported financials: 10-K / 10-Q figures, XBRL metrics, financial statements, filing text, metric history, or drivers.

Tools: `get_financial_metric`, `get_metric_history`, `get_financial_statement`, `search_filings`, `read_document_section`, `get_evidence_by_id`, `trace_financial_relationship`, `get_metric_drivers`, `resolve_financial_claim`, `get_adjustment_inputs`, `get_reporting_profile`.

Rules:

1. **Reported numbers only.** Tools return figures exactly as filed, with citations. Every number you state must come from a tool result and keep its citation (filing + release date). Never estimate or fill a gap from memory.
2. **Arithmetic is yours.** Deltas, ratios, bridges, derived quarters, and adjustments are not computed server-side — compute them from filed rows and show the inputs.
3. **Entities and periods.** `entity_id` accepts a ticker, company name, or CIK (resolved server-side). Periods: `FY2024` (annual), `2024-Q2` (fiscal quarter), an ISO date, or a calendar span like `3M ending 2024-06-30`. Metric aliases such as `revenue` or `operating cash flow` resolve server-side.
4. **Gaps are explicit.** A period no filing reports (a discrete Q4, a 3-month cash flow) comes back as a gap listing the adjacent reported spans — subtract those yourself and say you derived it. Do not retry other tools to "find" a number the filings do not contain.
5. **Precision and restatements.** Rows carry XBRL decimals precision and the assertion chain across filings; when a value was restated, report the latest assertion and note the restatement. Use `as_of_date` when the user asks what was known at a point in time.
6. **Retries.** Cap retries for the same failed call at **2** (3 attempts total), and only for clearly transient failures (timeouts, 429, 502/503/504). Do not retry validation or not-found errors. After the budget is exhausted, report the failure with the tool name and last error — never fall through to other tools or invented figures.
