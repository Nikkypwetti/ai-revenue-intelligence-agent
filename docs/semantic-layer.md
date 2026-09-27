# Agent v2 — KPI Semantic Layer Completion

## Status

Locally verified on the isolated Agent v2 deployment. The semantic-layer verifier also passes the complete Stage 4 → Stage 1 regression chain.

## Purpose

This milestone completes the semantic metadata required by the original KPI semantic-layer roadmap without replacing the KPI catalogue or approved query templates already built in Stages 2 and 3.

The existing KPI keys, versions, query keys, and runtime workflows remain unchanged.

## Existing components preserved

The implementation keeps:

- `governance.kpi_catalog`
- `governance.query_templates`
- the four existing KPI keys
- the four approved deterministic query templates
- existing `allowed_dimensions` and `allowed_filters` arrays
- the canonical `reporting.deals` model

## Added semantic metadata

The completion layer adds:

- explicit KPI calculation type and human-readable formula metadata
- `governance.dimension_catalog`
- `governance.date_field_catalog`
- `governance.filter_catalog`
- normalized KPI-to-dimension policies
- normalized KPI-to-filter policies
- a foreign-key boundary from KPI query keys to approved query templates
- deterministic semantic resolution through `governance.resolve_kpi_semantics`

## Canonical mappings

Current approved dimension mappings are:

- `sales_rep` → `reporting.deals.sales_rep`
- `lead_source` → `reporting.deals.lead_source`
- `deal_stage` → `reporting.deals.stage_name`

Current date mappings include:

- `closed_date` → `reporting.deals.closed_at`
- `expected_close_date` → `reporting.deals.expected_close_date`
- `created_date` → `reporting.deals.created_at`

`date_range` is a semantic filter. Its physical date column is resolved through each KPI's approved default date field.

## Deterministic boundary

Adding a string to a KPI's `allowed_dimensions` or `allowed_filters` array is no longer sufficient by itself.

The database trigger rejects dimensions or filters that are not active in their governed catalogues.

The semantic resolver only returns active, fully defined KPI definitions that map to an active approved query template and an active default date-field mapping.

It does not accept SQL from users or from an LLM.

The current Stage 3 scalar query templates remain date-bounded. This milestone governs which non-date dimensions and filters are approved; parameter binding for those filters belongs to the later deterministic agent/request resolver rather than generating SQL here.

## Initialize

```bash
bash scripts/init-semantic-layer.sh
```

The command is idempotent and uses the existing private deployment environment.

## Verify

```bash
bash scripts/verify-semantic-layer.sh
```

Verification checks semantic mappings, formula metadata, policy parity, least-privilege reader access, deterministic rejection of unsupported semantic fields, and the complete Stage 4 → Stage 1 regression chain.
