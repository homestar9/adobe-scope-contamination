# Adobe ACF 2023 Scope Contamination — Test Repository Handoff Plan

## Overview

Create a minimal, standalone ColdFusion test repository that Adobe engineers can quickly deploy and use to reproduce the ACF 2023 scope contamination bug. This repository should be self-contained, require no database, and provide clear instructions for triggering the bug under load.

**Primary Goal:** Give Adobe a deployable test harness without requiring them to navigate the production CCIS API codebase.

---

## Repository Structure

```
acf2023-scope-contamination/
├── README.md                          # Overview, setup, how to run tests
├── LICENSE                            # MIT or similar
├── .gitignore
├── SimpleBuilder.cfc                  # Minimal reproduction CFC (core bug pattern)
├── EntityWrapper.cfc                  # Two-layer wrapper mimicking QuickBuilder
├── test.cfm                           # Lightweight test endpoint for bombardier
├── test_contamination.cfm             # Full test harness with 3 modes
├── docs/
│   ├── PRODUCTION_EVIDENCE.md         # The forensic data from production
│   ├── BUG_EXPLANATION.md             # Technical deep-dive of the issue
│   └── INVESTIGATION_LOG.md           # Timeline of discovery
└── server.json                        # CommandBox server config (optional, for convenience)
```

---

## Files to Create / Copy

### 1. **README.md** — Main entry point

Should include:
- What the bug is (one-line summary)
- What to observe (tableContaminated, closureContaminated flags in JSON output)
- Three ways to reproduce:
  - Browser + bombardier external load test (recommended)
  - Built-in cfthread stress test
  - Single-threaded sanity check
- Expected output examples
- Link to `PRODUCTION_EVIDENCE.md` for forensic proof
- Expected timeline (30 seconds to 10 minutes depending on method)

### 2. **SimpleBuilder.cfc** — Core bug pattern

**Source:** Copy from `d:\Dropbox\Repositories\ccis-api\docs\adobe-repro\SimpleBuilder.cfc`

This CFC demonstrates the exact pattern:
- `variables.tableName` property set via `from()` method
- `columnFormatter` closure that captures `this`
- `getResult()` method that detects contamination

**No modifications needed** — this is the canonical minimal reproduction.

### 3. **EntityWrapper.cfc** — Two-layer pattern (mimics QuickBuilder → QuickQB)

**Source:** Copy from `d:\Dropbox\Repositories\ccis-api\docs\adobe-repro\EntityWrapper.cfc`

Wraps SimpleBuilder to show how the bug manifests when:
- One CFC creates another CFC
- Sets a closure on it that captures `this`
- That closure's `this` can resolve to the wrong instance under concurrent load

**No modifications needed.**

### 4. **test.cfm** — Lightweight endpoint for load testing

**Source:** Copy from `d:\Dropbox\Repositories\ccis-api\docs\adobe-repro\test.cfm` 

**Fix needed:** Ensure `fileAppend()` is used (not `fileWrite()`):
```cfml
fileAppend( expandPath( "./contamination_log.txt" ), logLine, "UTF-8" );
```

This endpoint:
- Accepts `?table=alpha` or `?table=bravo` parameter
- Creates one fresh EntityWrapper per request
- Returns JSON with contamination flags
- Logs any contamination to `contamination_log.txt` for easy post-analysis

**No heavy database or application setup required.**

### 5. **test_contamination.cfm** — Full harness with 3 modes

**Source:** Copy from `d:\Dropbox\Repositories\ccis-api\docs\adobe-repro\test_contamination.cfm`

Three execution modes:
1. **Sanity check (default)** — Single-threaded verification the harness works
2. **cfthread stress test** (`?stress=true&iterations=50000`) — Spawns thousands of concurrent threads
3. **External load test target** (`?entity=A` or `?entity=B`) — Designed to be hit by bombardier/hey/ab

**No modifications needed.**

### 6. **docs/PRODUCTION_EVIDENCE.md** — Forensic proof

Create a new file with the concrete production data:
- The actual SQL that failed: `UPDATE [user_type] SET [remoteAppId] = {NULL} ...`
- Expected SQL: `UPDATE [remote_app_remote_carrier] SET [remoteAppId] = {NULL} ...`
- Stack trace showing the call chain through QuickBuilder → QuickQB → Query execution
- Explanation: The `user_type` table doesn't have a `remoteAppId` column (proving contamination from unrelated entity)
- Production environment details: ACF 2023 Update 18, Windows Server 2022, IIS, ~50-100 concurrent users
- Frequency: Occurs several times per day in production

### 7. **docs/BUG_EXPLANATION.md** — Technical walkthrough

Explain:
- **What happens in production:** Quick ORM calls `updateAll()` on a relationship to set foreign keys to NULL
- **The pattern:** Entity A's QuickBuilder is created, set table to "remote_app_remote_carrier", closure captures `this`
- **The bug:** Under concurrent requests, Entity B's QuickBuilder's `variables.tableName` overwrites Entity A's `variables.tableName`
- **The result:** Entity A's query executes but targets Entity B's table (user_type)
- **Why it's hard to reproduce:** Requires specific JVM thread scheduling that aligns multiple concurrent CFC initializations
- **Existing vendor patch context:** There is already a patch for closure `this` contamination in QuickQB.applyColumnFormatter() — this is a second manifestation of the same root cause

### 8. **docs/INVESTIGATION_LOG.md** — Discovery timeline

Chronological log:
- When discovered (production error on date X)
- Initial hypothesis (wrong entity table being used)
- Investigation steps (traced code path, verified WHERE clause was correct, found table name was wrong)
- Root cause identified (variables scope contamination under concurrency)
- Connection to prior ACF bug (closure contamination, which was already patched)
- Workaround applied (reassert table name from stable source before query execution)
- Test validation (reproduction harness validates the fix)

### 9. **server.json** — Optional: CommandBox convenience wrapper

If using CommandBox (not required):
```json
{
    "name": "ACF 2023 Scope Contamination Test",
    "app": {
        "cfengine": "adobe@2023"
    },
    "web": {
        "http": {
            "port": 60830
        }
    }
}
```

Users can then: `box server start` to spin up a local server.

---

## Deployment Instructions

Adobe should be able to:

1. **Clone the repository** (or receive as zip)
2. **Deploy to ColdFusion 2023** (any setup method):
   - Copy files to webroot
   - Or use CommandBox: `box server start`
3. **Run sanity check** (verify it works):
   - Visit `http://localhost:8500/test_contamination.cfm` in browser
   - Should see green "OK" for table_alpha and table_beta
4. **Attempt reproduction** using one of three methods

---

## Reproduction Methods (in order of likelihood to trigger bug)

### Method 1: Built-in cfthread stress test (Highest likelihood)

Visit in browser:
```
http://localhost:8500/test_contamination.cfm?stress=true&iterations=50000
```

- Spawns 50,000 concurrent cfthreads
- Returns JSON summary
- Look for `totalContaminations > 0` and `contaminationRate > 0%`
- Should complete in ~30-60 seconds

### Method 2: External HTTP load test with bombardier (Recommended for real concurrency)

Open **two separate terminal windows** and run simultaneously:

**Terminal 1:**
```
bombardier -n 50000 -c 100 "http://localhost:8500/test.cfm?table=alpha"
```

**Terminal 2:**
```
bombardier -n 50000 -c 100 "http://localhost:8500/test.cfm?table=bravo"
```

Then check for contamination log:
```
type contamination_log.txt
```

### Method 3: Apache Bench (if bombardier unavailable)

Same pattern with `ab`:

**Terminal 1:**
```
ab -n 50000 -c 100 "http://localhost:8500/test.cfm?table=alpha"
```

**Terminal 2:**
```
ab -n 50000 -c 100 "http://localhost:8500/test.cfm?table=bravo"
```

---

## What to Look For

In JSON responses from `test.cfm` or `test_contamination.cfm`:

```json
{
  "contaminated": true,           // ← Flag this
  "requestedTable": "table_alpha",
  "test1_SimpleBuilder": {
    "expectedTable": "table_alpha",
    "actualTable": "table_bravo",  // ← WRONG TABLE — contamination!
    "tableContaminated": true      // ← Detection flag
  },
  "test2_EntityWrapper": {
    "entityTable": "table_alpha",
    "builderTable": "table_bravo",  // ← WRONG TABLE — contamination!
    "tableContaminated": true        // ← Detection flag
  }
}
```

Or in `contamination_log.txt`:
```
[...JSON with contaminated=true...]
[...JSON with contaminated=true...]
[...more contamination events...]
```

---

## If Reproduction Succeeds

If the bug is triggered:
- Collect the JSON output from one contaminated request
- Capture the contamination rate percentage
- Note the ColdFusion version and build number
- Send findings back with:
  - Number of contaminations
  - Rate of occurrence
  - Any error messages or stack traces
  - FusionReactor data if available

---

## If Reproduction Fails

If no contamination is detected after running all three methods:
- The bug is extremely timing-dependent and may not manifest in all environments
- Send findings back with:
  - ColdFusion version and build number
  - JVM flags (garbage collector, memory settings, etc.)
  - OS and CPU info (physical cores, logical cores)
  - Whether this was run on bare metal vs. VM
  - Number of requests attempted and whether they completed successfully

The existing production evidence and code inspection should be sufficient for Adobe's engineers to identify the root cause at the bytecode level.

---

## Key Points for Adobe

1. **Root Cause:** CFC `variables`-scoped properties and closure-captured `this` references lack proper JVM memory barriers under concurrent request load in ACF 2023.

2. **Scope of Issue:** Affects any code pattern where:
   - Multiple CFCs are created concurrently
   - They have mutable `variables`-scoped properties (especially strings, structs)
   - Closures capture `this` and are called after other concurrent requests may have modified state

3. **Production Impact:** Intermittent, but occurs several times per day under normal load.

4. **Existing Workaround:** Vendor patches confirm the issue — re-assert correct values from stable sources immediately before use.

5. **Related:** There is already a patch in Quick ORM for closure `this` contamination (`QuickQB.applyColumnFormatter()`). This test harness documents a second manifestation of the same root cause affecting `variables` property access.

---

## Handoff Checklist

- [ ] All 5 CFCs exist and are syntactically correct (SimpleBuilder, EntityWrapper, test.cfm, test_contamination.cfm, and any supporting CFCs)
- [ ] docs/PRODUCTION_EVIDENCE.md populated with real SQL/stack trace
- [ ] docs/BUG_EXPLANATION.md explains the technical details
- [ ] docs/INVESTIGATION_LOG.md documents discovery timeline
- [ ] README.md is clear and easy to follow
- [ ] Repository is deployable with no external dependencies (no database, no third-party modules)
- [ ] All three reproduction methods documented and tested
- [ ] server.json included for CommandBox convenience
- [ ] Git repo initialized, committed, and ready for Adobe to clone

---

## Success Criteria

Adobe has successfully received the handoff when:
1. They can deploy the repo to ACF 2023
2. They can run the sanity check and see it pass
3. They can attempt reproduction using at least one method
4. They understand what to look for (contamination flags in JSON)
5. They have clear documentation to send findings back

