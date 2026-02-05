# Repository Audit (镜像交付级盘点)

本文档为整理前的现状盘点，用于交付级项目整理参考。

## 1. 目录结构 (tree -L 3 等效)

```
/root/myspace_new
├── app/
│   ├── backend/
│   │   ├── main.py
│   │   └── __pycache__/
│   └── gateway/
│       ├── main.py
│       ├── schemas_chat.py
│       ├── schemas_openai.py
│       └── __pycache__/
├── cli_tests/
│   ├── bin/           # 00_check.sh, 70_*, 90_*, 95_*, 96~99, 100~103, common.sh, hang_infer_server.py, slow_infer_server.py
│   ├── assets/        # dog.png (img2img 测试用)
│   ├── out/           # 运行输出目录 (proof、FINAL_DELIVERY_REPORT.md)
│   ├── run_all_v2.sh  # 封板验收入口
│   ├── run_all.sh     # 旧版，建议归档
│   └── README.md
├── docs/
│   └── archive/
├── outputs/           # 网关静态托管目录 (运行产物)
├── logs/              # 运行时日志
├── scripts/           # smoke_test.sh
├── configs/           # 空目录
├── start.sh           # 主启动入口
├── VERSION
├── CHANGELOG.md
├── README.md
├── ENVIRONMENT.md
├── DELIVERABLE_SPEC.md
├── requirements.txt
└── (根目录散落) start*.log, cleanup_report.md, tree_structure.txt, inspect_pipe.py, pipeline_debug.py, stress_test_gateway.py, task*.json, test_queue.py, test.txt
```

## 2. 大文件排行 (du -ah --max-depth=3 | sort -hr | head)

| 大小 | 路径 |
|-----|------|
| ~22M | . (总) |
| ~8.9M | outputs/ |
| ~5.0M | .trash/ |
| ~4.0M | cli_tests/ |
| ~2.9M | cli_tests/out/ |
| ~2.4M | .git/ |
| ~1.3M | outputs/*.png (单文件) |
| ~1.2M | cli_tests/out/chat_txt2img.png, 101_downloaded.png |
| ~744K | logs/ |
| ~968K | cli_tests/assets/dog.png |

## 3. 可能的垃圾/运行产物目录

| 路径 | 说明 | 处理 |
|------|------|------|
| outputs/ | 网关生成图托管，运行产物 | 清空内容，保留目录 |
| cli_tests/out/ | 验收 proof、报告、临时 png/json/log | 清空内容，保留目录 |
| logs/ | 运行时 gateway/backend 日志 | 清空内容，保留目录 |
| **/__pycache__/, **/*.pyc | Python 缓存 | 删除 |
| 根目录 *.log | start.log, start_bg*.log, start_nohup*.log, start_test_70.log | 删除或移 logs/ |
| .trash/ | 历史备份 | 可选删除 |
| nohup.out, *.tmp, *.bak, *~, .DS_Store | 临时/备份 | 删除 |
| configs/ | 空目录 | 保留或移除 |

## 4. 当前有效入口

| 类型 | 入口 | 说明 |
|------|------|------|
| 启动 | `./start.sh` | 主服务：Gateway (PORT=8000) + Backend(s) (8001+) |
| 端口 | 8000 (Gateway), 8001+ (Backend) | 见 ENVIRONMENT.md PORT / BACKEND_PORT_START |
| 验收 | `./cli_tests/run_all_v2.sh` | 封板顺序：00/70/90/95/96~99/100~103 |
| 证据 | `cli_tests/out/FINAL_DELIVERY_REPORT.md` | ALL PASS 为交付证据 |

## 5. 验收入口与 proof 文件

- **run_all_v2.sh** 执行脚本顺序：00_check → 70_run_default_stable_and_save → 90_chat_adapter_smoke → 95_chat_img2img_smoke → 96_ready_probe → 97_openai_error_format → 98_async_first_platform_flow → 99_idempotency_smoke → 100_probe_alias_compat → 101_images_url_priority → 102_queue_full_429 → 103_timeout_504_and_backend_502
- **Proof 位置**：`cli_tests/out/` 下各脚本生成的 `*_proof.txt`、`101_downloaded.png`、`FINAL_DELIVERY_REPORT.md` 等。
- **禁止**：仓库内不得出现 pkill/killall/pgrep+kill 宽杀主服务的脚本（run_all_v2 静态扫描会拦截）。

## 6. 备注

- 本盘点在 pre_cleanup_snapshot 之后、实际清理之前生成，用于与整理后结构对比。
- 整理后目标结构见任务说明中的「目录结构调整到最合理的镜像交付形态」。
