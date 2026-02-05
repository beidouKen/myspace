# docs/archive 目录说明

## 用途

本目录用于存放**已归档的文档与脚本**，不再参与主流程，仅保留供查阅或历史对照。

## 内容来源

- **与 `pre_cleanup_snapshot` 的关系**  
  - **`pre_cleanup_snapshot/`** 是仓库在“清理/归档”**之前**的一次快照清单（见其下的 `MANIFEST.txt`），记录了当时计划要清理、归档或保留的项。  
  - **`docs/archive/`** 是执行该计划后，**实际被归档到这里**的一批文件：原位于仓库根目录或 `docs/` 下的旧脚本、调试用脚本、以及清理报告等，按 `MANIFEST.txt` 中 “To be archived” 的规划移入此处。

- **当前目录中的文件**  
  - `cleanup_report.md`：当时清理操作的报告。  
  - `tree_structure.txt`：当时仓库目录树快照。  
  - `inspect_pipe.py`、`pipeline_debug.py`、`stress_test_gateway.py`、`test_queue.py`：调试/压测用脚本。  
  - `task.json`、`task_resp.json`、`test.txt`：调试或示例产物。

以上内容不参与构建或日常运行；若需复用逻辑，请以主仓库中的正式脚本为准。
