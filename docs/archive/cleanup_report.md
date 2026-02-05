# Cleanup Report

**Timestamp**: 2026-01-28_073600 (approx)

## Cleanup Summary

### Moved Included Content

All items were moved to `/root/myspace_new/.trash/20260128_073600/` (exact timestamp depends on execution).

1.  **Python Cache**:
    *   Moved all `__pycache__` directories.
    *   Moved `*.pyc`, `*.pyo` files.
    *   Location: `.trash/.../pycache/`

2.  **Logs**:
    *   Old logs in `logs/` were moved.
    *   Root level `*.log` files were moved.
    *   Location: `.trash/.../logs_old/`
    *   *Note*: `logs/` directory recreated for new logs.

3.  **Outputs**:
    *   All old images in `outputs/` were moved.
    *   Location: `.trash/.../outputs_old/`
    *   *Note*: `outputs/` directory recreated.

4.  **CLI Tests Out**:
    *   Moved non-critical files from `cli_tests/out/`.
    *   **Kept Files**:
        *   `default_stable.png`
        *   `default_stable_proof.txt`
        *   `img2img_output.png`
        *   `img2img_proof.txt`
        *   `img2img_strength_ab.txt`
        *   `img2img_strength_02.png`
        *   `img2img_strength_08.png`
    *   Location: `.trash/.../cli_tests_out_old/`

5.  **Large Files (>100MB)**:
    *   Scanned for typically unwanted large files in repo (excluding .trash).
    *   Moved to: `.trash/.../large_files/`
    *   *Detail*: (No critical large files found outside of expected locations if empty here).

## Verification Results

*   **00_check.sh**: PASS (Ports active, Health OK, Models OK, Metrics OK).
*   **70_run_default_stable_and_save.sh**: PASS (Verified txt2img workflow, size constraints, clamping).
*   **82_img2img_strength_ab.sh**: PASS (Verified strength parameter effectiveness).

## Directory Structure (Post-Cleanup)

```
/root/myspace_new
├── .gitignore
├── .trash
│   └── 20260128_0737XX
├── app
│   ├── backend
│   │   ├── main.py
│   │   └── ...
│   ├── gateway
│   │   └── main.py
│   └── ...
├── cli_tests
│   ├── bin
│   │   ├── 00_check.sh
│   │   ├── 70_run_default_stable_and_save.sh
│   │   └── 82_img2img_strength_ab.sh
│   ├── out (Cleaned, only proofs kept)
│   │   ├── default_stable.png
│   │   └── ...
│   └── ...
├── configs
│   ├── task.json
│   └── ...
├── inspect_pipe.py
├── logs (Fresh logs)
│   ├── backend_0.log
│   ├── backend_1.log
│   └── gateway.log
├── outputs (Empty/Fresh)
├── pipeline_debug.py
├── README.md
├── requirements.txt
├── scripts
├── start.sh
├── stress_test_gateway.py
├── task.json
├── task_resp.json
├── test.txt
└── test_queue.py
```
