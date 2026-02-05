# Changelog

All notable changes to this project are documented in this file. Version format: see root `VERSION` file (semver or date-based, rollback-friendly).

## [1.0.1] - 2026-01-29

### Changed (Repo housekeeping)

- **Pre-cleanup snapshot**: Added `pre_cleanup_snapshot/MANIFEST.txt` before cleanup; generated `docs/REPO_AUDIT.md` (tree, du, junk list, entry points).
- **Cleanup**: Removed `**/__pycache__/`, `*.pyc`, cleared `outputs/`, `logs/`, `cli_tests/out/` (directories kept); removed root stray `*.log`, `.trash`, temp files.
- **Archive**: Moved `cli_tests/run_all.sh` to `cli_tests/archive/run_all.sh` (DEPRECATED, use `run_all_v2.sh`); moved obsolete docs/debug files to `docs/archive/` (cleanup_report.md, tree_structure.txt, inspect_pipe.py, pipeline_debug.py, stress_test_gateway.py, task_resp.json, task.json, test_queue.py, test.txt).
- **Docs**: README.md rewritten as delivery entry page; ENVIRONMENT.md as config one-stop; added `docs/ARCHITECTURE.md`, `docs/API.md`, `docs/TESTING.md`, `docs/OPERATIONS.md`.
- **.gitignore**: Explicit entries for `outputs/**`, `logs/**`, `cli_tests/out/**`, `**/__pycache__/`, `*.pyc`, `nohup.out`, temp/backup patterns.
- **DELIVERABLE_SPEC.md**: Acceptance seal uses `run_all_v2.sh`; proof and report paths unchanged.

### Unchanged

- Gateway/Backend behavior, APIs, error envelope, queue, healthz/readyz, url-first. No broad-kill scripts. `./start.sh` and `./cli_tests/run_all_v2.sh` ALL PASS remain the delivery criteria.

## [1.0.0] - 2025-01-29

### Added

- **Delivery seal**: DELIVERABLE_SPEC.md (acceptance criteria), ENVIRONMENT.md (defaults/required/CUDA_VISIBLE_DEVICES), CHANGELOG.md, VERSION.
- **run_all.sh**: `cli_tests/run_all.sh` runs 00/70/90/95/96~99/100~103 in order, output to `cli_tests/out/`, generates `FINAL_DELIVERY_REPORT.md`.
- **101_images_url_priority.sh**: Verifies url-first response and downloadable image (proof: 101_images_url_priority_proof.txt, 101_downloaded.png).
- **102_queue_full_429.sh**: Triggers 429 queue_full with temp gateway QUEUE_SIZE=1 (proof: 102_queue_full_429_proof.txt).
- **103_timeout_504_and_backend_502.sh**: Part A 502, Part B 504 sync_wait_timeout, Part C 504 task_timeout (proof: 103_timeout_504_502_proof.txt, 103_timeout_task_timeout_proof.txt).

### Changed

- **103 Part C risk收口**: slow_infer_server 兜底改为显式启用。默认优先走真实 backend `INFERENCE_TIMEOUT_SEC=1` 触发 task_timeout；仅当 `USE_SLOW_INFER_FALLBACK=1` 或 103 脚本参数 `--fallback` 时使用 slow_infer_server（无 GPU 环境）；proof/报告中标注 RUN_MODE。
- **start.sh**: 启动自检 MODEL_DIR 存在、OUTPUTS_DIR 可写；失败即 exit 1 并打印明确错误；启动仍打印有效配置摘要。
- **ENVIRONMENT.md**: 补齐默认值/必须项/示例，明确尊重外部 CUDA_VISIBLE_DEVICES；补充 INFERENCE_TIMEOUT_SEC、103 fallback 说明。

### Fixed

- None in this release.
