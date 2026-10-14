# Documentation

Read in this order if you are new here: the [project README](../README.md) for the summary and
history, then [background](#background), then the hotfix results.

## Background

| Document | What it covers |
|---|---|
| [PRODUCTION_EVIDENCE.md](background/PRODUCTION_EVIDENCE.md) | The production failure: real SQL, stack trace, environment |
| [BUG_EXPLANATION.md](background/BUG_EXPLANATION.md) | A technical explanation of the contamination |
| [INVESTIGATION_LOG.md](background/INVESTIGATION_LOG.md) | How the bug was found and narrowed down |
| [LOCAL_REPRODUCTION_RESULTS.md](background/LOCAL_REPRODUCTION_RESULTS.md) | The first local reproduction: observed rates and tuning |

## Adobe's hotfixes

All four are builds of hotfix `hf202300-4232227`, numbered in the order they arrived.

| Document | What it covers |
|---|---|
| [1-first-hotfix-static-analysis.md](adobe-hotfixes/1-first-hotfix-static-analysis.md) | What the first hotfix changes, including its global construction lock |
| [1-first-hotfix-performance.md](adobe-hotfixes/1-first-hotfix-performance.md) | Its throughput cost and thread-dump evidence of the lock |
| [2-second-hotfix-static-analysis.md](adobe-hotfixes/2-second-hotfix-static-analysis.md) | Why the second hotfix is identical to code already in Update 23 |
| [2-second-hotfix-correctness.md](adobe-hotfixes/2-second-hotfix-correctness.md) | Its contamination test results |
| [3-third-hotfix-static-analysis.md](adobe-hotfixes/3-third-hotfix-static-analysis.md) | What the third hotfix changes (per-class locks), with predictions made before testing |
| [3-third-hotfix-results.md](adobe-hotfixes/3-third-hotfix-results.md) | Its lock stress tests, lock evidence, endurance test and first throughput results |
| [3-third-hotfix-contamination-and-other-engines.md](adobe-hotfixes/3-third-hotfix-contamination-and-other-engines.md) | The large contamination test (900,000 requests), its throughput cost under heavy load, and Lucee 6 and BoxLang on the same application |
| [4-fourth-hotfix-static-analysis.md](adobe-hotfixes/4-fourth-hotfix-static-analysis.md) | What the fourth hotfix changes (one method, no lock: compiler temporaries kept in the function local scope), why that is the cause found in August, and the predictions made before testing |
| [4-fourth-hotfix-results.md](adobe-hotfixes/4-fourth-hotfix-results.md) | Its contamination tests, the mechanism probe, lock evidence, lock stress tests, throughput and endurance results |
| [5-final-v4-vs-stock.md](adobe-hotfixes/5-final-v4-vs-stock.md) | One page: stock Update 23 against the fourth hotfix, is the contamination fixed and does it cost speed |

## Root cause

| Document | What it covers |
|---|---|
| [contamination-investigation-and-startup-crash-fix.md](root-cause/contamination-investigation-and-startup-crash-fix.md) | The two engine bugs, the one-line fix for the startup crash, and what we measured about the contamination |
| [how-lucee-and-boxlang-avoid-it.md](root-cause/how-lucee-and-boxlang-avoid-it.md) | How the two other CFML engines avoid both bugs without a lock |

## Guides

| Document | What it covers |
|---|---|
| [TESTING_GUIDE.md](guides/TESTING_GUIDE.md) | The test servers, every test, and how to run and read them |
| [THREAD_DUMP_GUIDE.md](guides/THREAD_DUMP_GUIDE.md) | How to read the thread dumps: which lock, which frames, what they show |

## Research log

[research-log/](research-log/README.md) holds dated notes from the August 2026 investigation:
our own experimental builds, the probes that ruled causes out, and the Quick defensive patches.
They are kept so every number in the documents above can be traced.
