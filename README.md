# ACF 2023 — CFC `variables`-Scope / Closure Contamination Under Concurrency

A minimal, deployable reproduction harness for an intermittent **Adobe ColdFusion 2023**
concurrency defect: under concurrent request load, a **transient CFC's `variables`-scoped
state is contaminated by a different concurrent instance**. In production this caused a
Quick ORM query builder's table name to be overwritten by an unrelated entity's table,
producing SQL like `UPDATE [user_type] ...` when it should have been
`UPDATE [remote_app_remote_carrier] ...`.

This repo uses **stock, unpatched** ColdBox + Quick ORM against SQL Server and exercises the
exact production code path. It is self-contained: two tiny entity pairs, a couple of
endpoints, and built-in contamination detection/logging.

> **TL;DR for Adobe:** deploy to ACF 2023, create the `adobe-temp` datasource, run
> `resources/schema.sql`, then hammer `/repro/alpha` and `/repro/bravo` concurrently (or hit
> `/repro/stress`). Watch `logs/contamination_log.txt`. Full forensic write-up is in
> [`docs/`](docs/).

---

## What you're looking for

A transient CFC, freshly created per request via WireBox `getInstance()`, intermittently
ends up with a `variables`-scoped property whose value belongs to a **different concurrent
instance**. Two observed manifestations (same root cause):

1. **Closure captured `this`** resolving to the wrong instance.
2. **A `variables`-scoped property** (e.g. a query builder's `tableName`) holding another
   instance's value.

See [`docs/BUG_EXPLANATION.md`](docs/BUG_EXPLANATION.md) and
[`docs/PRODUCTION_EVIDENCE.md`](docs/PRODUCTION_EVIDENCE.md).

---

## Prerequisites

- Adobe ColdFusion 2023 (Update 18 / build 330879 is where production runs; any 2023 build
  is fine).
- Microsoft SQL Server reachable from the CF server.
- The SQL Server JDBC driver available to CF (bundled with ACF; on a fresh install ensure
  the `sqlserver` package is installed via `cfpm install sqlserver`).

---

## Setup

### 1. Deploy the code (with dependencies)

The framework dependencies (`coldbox/` and `modules/` — ColdBox + stock Quick/qb/mementifier)
are **not committed** to git. Populate them once with CommandBox before deploying:

```bat
box install
```

This downloads ColdBox into `coldbox/` and Quick (plus qb, mementifier, etc.) into `modules/`.
Then copy the **entire folder — including `coldbox/` and `modules/`** — to your ACF webroot
(IIS site root). The application bootstraps ColdBox via `Application.cfc`; there is no compile
step. (If you received this as a zip that already contains `coldbox/` and `modules/`, you can
skip `box install`.)

### 2. Create the database

Create an empty database (the examples assume one named `adobe-temp`), then load the schema:

```bat
sqlcmd -S localhost,1433 -U sa -P <password> -d adobe-temp -i resources\schema.sql
```

This creates two independent parent/child pairs with **differently-named FK columns**
(`alpha_child.alpha_parent_id`, `bravo_child.bravo_parent_id`) and seeds a few rows. The
differing FK names are what make contamination self-evident: a contaminated `UPDATE` aimed
at the wrong child table references a column that table does not have, so SQL Server raises
`Invalid column name ...` — exactly mirroring production (`user_type` had no `remoteAppId`).

### 3. Create the `adobe-temp` datasource (IIS / standalone ACF)

In the **ColdFusion Administrator** → **Data & Services → Data Sources**, add:

| Field | Value |
|-------|-------|
| Data Source Name | `adobe-temp` |
| Driver | Microsoft SQL Server |
| Database | `adobe-temp` (your DB name) |
| Server / Host | `localhost` (or your SQL host) |
| Port | `1433` |
| Username / Password | your SQL credentials |

The application reads `this.datasource = "adobe-temp"` (in `Application.cfc`), so the
datasource **name must be `adobe-temp`**. Click *Submit* and verify the datasource reports
*OK*.

> Using a different DB or datasource name? Change the target DB in step 2 and the
> `this.datasource` value in `Application.cfc` to match.

### 4. (Optional) CommandBox instead of IIS

If you have CommandBox, the datasource and SQL Server engine package are wired for you:

```bat
box install
box server start
```

`server.json` targets `adobe@2023` and `.cfconfig.json` (auto-imported by
`commandbox-cfconfig`) defines the `adobe-temp` datasource from values in `.env`. Set your
DB host/credentials in `.env` first (copy `.env.example`). The server listens on port
`60830`.

---

## Running the reproduction

Replace `<base>` with your server base URL (IIS: `http://localhost`; CommandBox:
`http://localhost:60830`).

### A. Single-threaded sanity check (should succeed)

```
GET <base>/repro/alpha
GET <base>/repro/bravo
```

Each returns `{"ok":true,"childCount":3,...}` and runs the correct `UPDATE`. This confirms
the harness and datasource work. `GET <base>/repro/status` shows the running contamination
tally.

### B. External HTTP load — the canonical method

The defect is **request-scoped**, so drive real concurrent requests. Open **two terminals**
and run simultaneously (using [bombardier](https://github.com/codesenberg/bombardier), a
single Windows-friendly binary; `ab`/`hey` work too):

```bat
:: Terminal 1
bombardier -n 200000 -c 100 "<base>/repro/alpha"

:: Terminal 2
bombardier -n 200000 -c 100 "<base>/repro/bravo"
```

### C. In-process stress (convenience)

```
GET <base>/repro/stress?entity=alpha&iterations=200
GET <base>/repro/stress?entity=bravo&iterations=200
```

Spawns up to 500 concurrent `cfthread`s, each constructing fresh transients and running the
dissociate. Returns a JSON summary with `threadErrors` and sample messages. In the author's
testing this reliably reproduced the corruption at ~4–7% of constructions — see
[`docs/LOCAL_REPRODUCTION_RESULTS.md`](docs/LOCAL_REPRODUCTION_RESULTS.md).

---

## What success looks like

Contamination events are written to **`logs/contamination_log.txt`**, one JSON object per
line, tagged by type:

- `VARIABLES_SCOPE_CORRUPTION` — a transient's `variables` property held another instance's
  value. Two observed faces of this, same root cause:
  - the entity's injected `_str` helper resolved to an unrelated value:
    `Element _STR is undefined in a Java object of type class [Ljava.lang.String;`.
  - the entity's cached metadata (`variables._meta`) crossed instances, so Quick could not
    find the entity's own relationship and forwarded the call to qb:
    `Quick couldn't figure out what to do with [setAlphaChildren]... Method does not exist on
    QueryBuilder [setAlphaChildren]`.
- `TABLE_NAME_CONTAMINATION` — an `UPDATE` hit the wrong table (`Invalid column name ...`),
  the exact production symptom. Also flagged proactively by
  `interceptors/ContaminationDetector.cfc` on qb's `preQBExecute`.

> **Reading the counters.** The `contaminations` field (in `/repro/status` and the stress
> JSON) counts **only** `TABLE_NAME_CONTAMINATION`, which `ContaminationDetector` catches at
> qb's `preQBExecute`. The `VARIABLES_SCOPE_CORRUPTION` manifestations fail *before* any SQL
> is generated, so they surface in `threadErrors` and in `logs/contamination_log.txt` — **not**
> in the `contaminations` counter. A non-zero `threadErrors`, or any line in the log, is a
> positive reproduction even when `contaminations` reads `0`.

Example:

```
VARIABLES_SCOPE_CORRUPTION {"type":"VARIABLES_SCOPE_CORRUPTION","context":"stress(alpha)",
"message":"Element _STR is undefined in a Java object of type class [Ljava.lang.String;.",
"thread":"...","detectedAt":"2026-05-28 23:19:44.467"}
```

Any entry, or any non-zero `threadErrors` / `/repro/status` count, is a positive
reproduction. A single request never produces these; they appear only under concurrency.

If you see **nothing** after sustained load, the timing window simply isn't opening on that
hardware — note CPU core count, bare-metal vs VM, request volume, and duration, and see the
forensic docs, which stand on their own.

---

## Repository layout

```
Application.cfc                     ColdBox bootstrap; this.datasource = "adobe-temp"
config/Coldbox.cfc                  pins SqlServerGrammar@qb; registers the detector
config/Router.cfc                   /repro/* routes
models/AlphaParent|AlphaChild       entity pair A  (alpha_child.alpha_parent_id)
models/BravoParent|BravoChild       entity pair B  (bravo_child.bravo_parent_id)
handlers/Repro.cfc                  alpha / bravo / status / stress endpoints + logging
interceptors/ContaminationDetector  preQBExecute table/column-prefix mismatch detector
resources/schema.sql                SQL Server schema + seed
logs/contamination_log.txt          created at runtime when contamination is detected
docs/                               forensic write-up (below)
```

### Documentation

- [`docs/PRODUCTION_EVIDENCE.md`](docs/PRODUCTION_EVIDENCE.md) — real SQL, stack trace, env.
- [`docs/BUG_EXPLANATION.md`](docs/BUG_EXPLANATION.md) — root-cause analysis.
- [`docs/LOCAL_REPRODUCTION_RESULTS.md`](docs/LOCAL_REPRODUCTION_RESULTS.md) — observed rates.
- [`docs/INVESTIGATION_LOG.md`](docs/INVESTIGATION_LOG.md) — discovery timeline.

---

## Notes

- Quick is installed **stock and unpatched** from ForgeBox; the production vendor
  workarounds are intentionally **absent** so the raw engine behavior is observable.
- The same application code runs without these issues on Lucee Server.
- Questions / additional captures (FusionReactor, thread/heap dumps) available on request —
  contact: dave@angrysam.com.
