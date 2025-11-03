## v2.2.1
- Merge feature/monitor-stats-log into main
- Stabilize monitor/log/stats linkage
- NDJSON 只经 stdout；文本日志只经 stderr
- 修复 printf 格式化（%zu/PRIu64 等）
- 调整 monitor 参数解析（--interval / --watch）
