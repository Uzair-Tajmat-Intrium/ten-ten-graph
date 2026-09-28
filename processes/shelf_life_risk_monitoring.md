# `shelf_life_risk_monitoring.yaml` — block-by-block

A reference for every block in the process file: what it is, what each field does,
and which part of the engine reads it.

---

## Top level

```yaml
version: 1
processes:
  - id: shelf_life_risk_monitoring
    name: Shelf-Life Risk Monitoring
    description: |
      ...
    domain: SupplyChain
    owner: supply_chain_team
```

- **`version`** — file schema version for the loader.
- **`processes`** — a list; one file can define several. Each is one process.
- **`id`** — the stable key. This is what a trigger *pins* to (`process_id`) and what
  the API/logs reference. Never change it once live.
- **`name`** — human label shown in the UI.
- **`description`** — free text; documentation only, not executed.
- **`domain` / `owner`** — organisational tags (grouping / who owns it). Metadata only.

---

## `applies_to` — which entities this process attaches to

```yaml
applies_to:
  - entity: Store
  - entity: Store
    where:
      - { field: id, op: ne, value: __none__ }
```

Declares the entity **type(s)** this process is about. Two bindings on purpose:

1. **`- entity: Store`** — a *type-level* binding. Enough for the scheduled trigger,
   which pins the process by id (no per-entity matching needed).
2. **`- entity: Store` + `where`** — a *filter* binding. At apply time this becomes a
   `meta.ProcessAttachment` that matches **every** Store instance. It's what lets
   **discovery** find this process for a manually-fired, entity-specific event
   (`/entities/{id}/processes`). The condition `id != "__none__"` is always true, so it
   matches all stores.

> Without the filter binding, a manual `shelf_life_risk` event for one store returns
> *"no applicable process found"* (a bare type binding doesn't create the attachment
> discovery looks for).

**Read by:** the context-graph store at apply time (attachments), and
`orchestrator.find_applicable_process` at run time.

---

## `triggers` — when it runs

```yaml
triggers:
  - { type: schedule, cron: "*/8 * * * *" }
  - { type: event, event_type: shelf_life_risk }
  - { type: manual, allowed_roles: [SupplyPlanner, DemandPlanner] }
```

- **`schedule`** — a cron timer. This is the live path today (fires every 8 min via the
  scheduled-pull trigger).
- **`event`** — lets an inbound event of type `shelf_life_risk` match this process
  (used by discovery + as the `event_type` on any child events).
- **`manual`** — allows the listed roles to run it by hand.

**Read by:** the trigger framework, and the `event_type` gate in
`find_applicable_processes`.

---

## `metadata` — the part the orchestrator actually executes

Everything below lives under `metadata:`. The blocks above are mostly *matching*
config; these are *runtime* config.

```yaml
metadata:
  version: 1
  effective_from: 2026-07-15
  priority: 10
  requires_human_approval: true
```

- **`version` / `effective_from`** — bookkeeping (which revision, since when).
- **`priority`** — tie-breaker when several processes match one event; higher wins
  (`ProcessSelector`).
- **`requires_human_approval`** — `true` forces the run to **pause** for a reviewer
  (`WAITING_FOR_FEEDBACK`) instead of auto-executing. Read by
  `orchestrator.requires_human_approval`.

---

### `context_package` — the data to gather (before any recommendation)

```yaml
context_package:
  - key: at_risk_products
    source: dataset_search
    required: true
    query: { ... }
    post: { ... }
  - { key: scheduled_at, source: event, required: false }
```

Each entry is one fact to collect. Read by `ContextCollector.collect`.

- **`key`** — the fact name (`context.facts[key]`), and the column key the UI table uses.
- **`source`** — where to get it:
  - `event` → an attribute off the incoming payload (`scheduled_at`).
  - `graph` → a property already on a resolved entity.
  - `connector` → a record the enrichment step hydrated.
  - `dataset` → a linked dataset scoped to **one** resolved entity.
  - `dataset_search` → a linked dataset **across all** entities of a type ← used here.
- **`required`** — if `true` and it can't be resolved, it's recorded as *missing*
  (the run still continues).

#### `query` — what `dataset_search` fetches

```yaml
query:
  entity_type: Store
  dataset: STORE_INVENTORY_DAILY
  columns: [store_id, product_sku, available_quantity, expiry_date, snapshot_date, batch_row_number]
  order_by: snapshot_date
  order_dir: desc
  limit: 5000
```

- **`entity_type`** — the dataset's entity type (Store). Not one instance — all of them.
- **`dataset`** — the linked source table (`STORE_INVENTORY_DAILY`).
- **`columns`** — which columns to pull back.
- **`order_by` / `order_dir`** — newest snapshots first (raw pull; filtered below).
- **`limit`** — pull wide (5000) because `post` then reduces it to just the at-risk rows.

**Read by:** `ContextCollector.fetch_dataset_search` → `client.search_dataset`.

#### `post` — reduce the raw rows to the decision (in code, deterministic)

```yaml
post:
  latest_by: [store_id, product_sku, batch_row_number]
  latest_on: snapshot_date
  compute:
    - { as: days_to_expiry, days_until: expiry_date }
  where:
    - { field: days_to_expiry, op: gte, value: 0 }
    - { field: days_to_expiry, op: lte, value: 3 }
    - { field: available_quantity, op: gt, value: 0 }
  sort_by: days_to_expiry
  resolve:
    - { field: store_id, type: Store, as: store_name }
    - { field: product_sku, type: Product, as: product_name }
```

Runs in order (`ContextCollector._postprocess` + `_resolve_row_names`):

1. **`latest_by` + `latest_on`** — keep only the newest `snapshot_date` per
   store/SKU/batch (drop stale snapshots).
2. **`compute`** — add `days_to_expiry` = whole days from today to `expiry_date`
   (blank if the date is null/unparseable).
3. **`where`** — keep only rows within the 3-day window (`0..3`) that still have stock
   (`available_quantity > 0`). This is the "what's at risk" decision — no LLM.
4. **`sort_by`** — most urgent (smallest `days_to_expiry`) first.
5. **`resolve`** — turn ids into names via the graph (`store_id → store_name`,
   `product_sku → product_name`), inserted right after each id. Cached per unique id.

The result is stored as the fact → it's what the table shows, what the email sends, and
the only rows the recommender sees.

---

### `policy_rules` — instructions for the recommender

```yaml
policy_rules:
  - "`at_risk_products` has ALREADY been filtered ... Do NOT re-filter or re-list every row."
  - "Write a SHORT decision summary ... Do not paste the table."
  - "Recommend APPROVE to email ... If empty, recommend no action."
```

Plain-language guardrails fed to the LLM (`RecommendationEngine.generate`). Because the
data is pre-filtered, these tell it to **summarise, not re-filter** — which keeps the
reasoning short. They don't run code; they shape the recommendation text and decision.

---

### `actions` — what executes per decision

```yaml
actions:
  - name: email_at_risk_report
    decision: APPROVE
    connector: email
    config: { type: email, to: ..., subject: ..., body: "... {{facts.at_risk_products}} ..." }
  - name: hold_no_action
    decision: REJECT
    connector: notify
    config: { type: notify, ... }
  - name: escalate_review
    decision: ESCALATE
    connector: simulated
    config: { type: simulated, ... }
```

One action per decision verb. When the reviewer's decision matches an action's
**`decision`**, that action runs (`select_actions` → `ActionExecutor.execute`).

- **`name`** — identifier for the action (shown in the plan / audit).
- **`decision`** — which verb triggers it: `APPROVE` / `REJECT` / `ESCALATE`.
- **`connector`** — which connector delivers it (`email`, `notify`, `simulated`, …).
- **`config`** — handler params. Strings may contain **`{{facts.x}}`** templates, which
  the dispatcher renders against the collected facts before running — so
  `{{facts.at_risk_products}}` in the email body becomes the actual at-risk rows.

Here: **APPROVE** emails the report; **REJECT** just logs a hold; **ESCALATE** is a
placeholder (no external effect).

---

## One-paragraph summary

`applies_to` + `triggers` decide **when/where** this process runs; `metadata` is
**what runs**: `context_package` gathers + filters the data (the real decision happens
in `post`), `policy_rules` tells the LLM to summarise it, `requires_human_approval`
pauses for a reviewer, and `actions` fire on their matching decision (APPROVE → email).
