# pm.sh Refinements — Status

## ✅ Resolved

| # | Fix | Status |
|---|-----|--------|
| 1 | Redundant `artifact_dir` in `run_docker` | ✅ Removed |
| 2 | `tty_flag` quoting → `run_args` array | ✅ Fixed |
| 3 | Unquoted `$artifacts` in `copy_artifacts` | ✅ Now `"${artifacts[@]}"` |
| 4 | Empty `cmd` validation | ✅ Added check + exit |
| 5 | Redundant `artifact_dir` in `run_native` | ✅ Removed |
| 6 | Required field validation (`name`, `source`, `artifact_dir`) | ✅ Early validation loop |
| 7 | `cache_volumes` / `env` defaults | ✅ Both have `// {}` fallback |
| 16 | `clear` guarded with tty check | ✅ `[[ -t 1 ]] && clear` |

## ⏭️ Deferred / Won't Fix

| # | Fix | Decision |
|---|-----|----------|
| 8 | Docker image cleanup / pruning | Handled externally |
| 9 | Fingerprint edge case | Acceptable for MVP |
| 10 | Instructions path resolution | By design — resolves from CWD |

## 🟡 Schema Decisions (Pre-Schema)

| # | Field | Decision Needed |
|---|-------|----------------|
| 11 | `description` on actions | Required or optional? |
| 12 | `interactive` on docker actions | Type: boolean |
| 13 | `base_image` on agent | Optional, default `"pi-agent"` |
| 14 | `artifacts` on native actions | Optional |

## 🟢 Remaining Minor

| # | Fix | Priority |
|---|-----|----------|
| 15 | Style: `if [ -z "$cmd" ]` → `if [[ -z "$cmd" ]]` for consistency | Low |
| 17 | `--provenance=false` BuildKit-only flag | Low (controlled env) |
