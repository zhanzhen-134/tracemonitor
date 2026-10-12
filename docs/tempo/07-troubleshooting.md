# 故障定位

所有 K8s 命令带 `-n "$TEMPO_NAMESPACE"`。先记录当前时间、trace ID、变更版本，再查事件、Pod 日志与指标，不急于删除 PVC/Topic。

| 现象 | 检查顺序 | 处理 |
|---|---|---|
| Pod Pending | describe pod、requests/limit、SC、PVC AZ、zone label/affinity | 增补资源或修正真实标签；不放宽安全约束掩盖容量不足 |
| Collector 无输入 | SDK endpoint/protocol/CA/client cert/namespace label | gRPC 用 4317，HTTP 用 4318/v1/traces；检查 SAN 与 NetworkPolicy |
| Collector queue 高 | exporter failed、Distributor Ready、Kafka 写延迟 | 修复下游，减少接入/SDK head sampling，必要时扩 distributor；重启可能丢队列 |
| Kafka SASL/TLS 错误 | 机制、用户名、Secret env、CA、advertised broker、ACL | 修复账号权限或路径；不要 insecure skip verify |
| Message too large | Topic/broker/replica fetch 限制、超大属性 | >=16000000；评审 broker 影响，业务限制 span 大小 |
| Live Store 不 ready | 分区 owner/ACTIVE、lag、memberlist 7946、可用区副本 | 排查 Kafka 消费；readiness_target_lag=5s 追平后才 Ready |
| 近期可查长期不可查 | builder lag、flush、MinIO PUT/GET、blocklist poll | 修复 S3 权限/证书，等重放追平；retention 到期之前恢复 |
| backend task 积压 | scheduler 单实例、PVC、worker RPC、S3 | 恢复 scheduler 或扩 worker；不要把 scheduler 扩 2 |
| 查询慢/429/5xx | QF 队列、Querier CPU、并发、大时间窗、S3 latency | 限制查询时间范围并扩 querier；缓存需另行容量评估后开启 |
| 无派生指标 | processors、Kafka group lag、WAL、remote-write 4xx | 启用 receiver/正确 auth；避免反复重启 generator |
| Service Graph 缺边 | 两侧 span/parent context、采样一致性、wait 与丢弃 | 检查传播和 unmatched 边，避免每层随机采样 |
| target missing | ServiceMonitor label/namespaceSelector、端口名 | 检查两层选择器与网络策略；缺系列不等于零故障 |
| webhook 拒绝 drain（仅双可用区模式） | operator 健康、同 partition 另一 AZ、CRD/cert | 恢复另一 owner 或 operator；不可无评审删除 webhook |
| Logs 无关联 | trace_id keyword、时间窗口、JSON 解码、Grafana UID | 检查 ES mapping 与数据源，不把全部 trace 写 ES |

常用只读命令：`kubectl ... get events --sort-by=.lastTimestamp`、`kubectl ... describe pod <pod>`、`kubectl ... logs <pod> --all-containers --since=15m`、`kubectl ... logs <pod> --previous`。输出可能含连接地址/业务数据，按敏感日志管理。
