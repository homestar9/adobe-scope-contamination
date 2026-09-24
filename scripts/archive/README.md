# Retired jar-building tools

These built the local hotfix derivatives that were tested in July and August 2026
(`-unlocked`, `-stripe`, `-v3`, `-concmap`, `-concmap-v1`, `-trace`, `-trace-locked`).
They are kept so the record in `docs/research-log/` stays reproducible, and they are not maintained.

To rebuild any of them: fetch the ASM jars with `scripts/Get-BenchmarkTools.ps1`, put Adobe's
v1 jar at `hotfixes/hf202300-4232227-adobe-v1.jar`, update the `$v1Jar` path inside
`Build-UnlockedJar.ps1` (it still expects the old bare filename), and run it with the mode switch
you want. Each mode prints the SHA256 of the jar it produced; the audited values are in the docs.
