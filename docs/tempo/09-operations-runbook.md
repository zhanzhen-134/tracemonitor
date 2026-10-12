# 生产运行与演练

日常：检查入口 accepted/refused、exporter failures/queue、Kafka lag 秒数与 retention 剩余时间、每 partition owner、builder flush、S3 错误/时延、query p95/5xx、generator WAL/remote write、Pod OOM/restart。告警阈值以压测校准，重要链路缺失指标也需要告警；每班执行一条带真实 trace ID 的合成查询。

每周：检查 Topic ISR、磁盘、对象存储容量与 compaction，Prometheus 系列 churn、证书到期、备份可恢复性；每月审查新服务维度/采样比与权限。SRE 负责组件和版本；业务开发负责 context 传播/敏感属性；各平台负责人负责共享设施变更。

演练前确认审批、测试窗口、停止条件、基线吞吐和 RPO/RTO。一次只注入一个故障，先预生产，保留响应与监控证据。

| 场景 | 注入方式 | 预期/恢复 | 可能的数据损失 |
|---|---|---|---|
| Collector 重启 | 单 Pod 滚动，观察队列 | 其他副本继续接入，SDK 重试；恢复副本 Ready | 内存队列、batch 未发送部分可丢，缩容同样如此 |
| Distributor 重启 | 只重启一个 Pod | SDK/Collector retry，其他副本继续写 Kafka | 超出重试/队列容量或未确认请求可能丢/重复 |
| Block Builder 重启 | 单 ordinal 重启 | 从已提交 offset 重放、lag 短升、恢复 flush | Kafka retention 已过或 offset 错误时不可恢复 |
| Live Store 重启 | 双可用区：仅一个 AZ 的一个 owner；单可用区：任一 live-store | 双可用区：另一 AZ 服务最近查询；单可用区：该分区近期 trace 暂时查不到。重启追平后 Ready | 数据在 Kafka 中可重放，不丢失；单可用区或两区同时失效会影响近期可见性 |
| MinIO 短时不可用 | 仅对测试 namespace 阻断 S3 egress | builder/worker 报错，历史查询失败，Kafka 积压；撤销策略后追平 | 超过 Kafka retention 且未落盘会丢 trace |
| Kafka 消费积压 | 预生产限流消费端或受控增压 | lag/磁盘告警，停止注入，扩容量与恢复消费 | 积压年龄超过 retention 则数据已过期 |
| Remote Write 故障 | 仅测试 generator→receiver 阻断 | WAL/失败告警，trace 查询仍正常；恢复 receiver 后观察重试 | 超过 WAL/ingestion slack 或旧样本限制可丢指标 |
| 单 AZ 失效（仅双可用区模式） | 经平台批准节点/网络演练 | 另一区 owner 继续查询，Kafka/S3 本身仍需 HA | 不承诺平台 quorum 同时失效时零丢失 |

停止条件：写入错误超 SLO、Kafka 剩余容量不足、未消费年龄接近 retention 的 50%（示例，按 RTO 调整）、第二故障域异常。恢复后观察 lag 回归、队列稳定、同一 ID backend 查询、派生指标与日志关联，而不是仅等待 Pod Running。

OTel queue_size=2048 默认按请求/批次数计，不是 span 数；send_batch_max_size=1024、内存 limiter=768Mi，实际可用队列受 span 大小/内存限制影响。max_elapsed_time=300s 后仍失败的批次会丢；内存队列重启丢失。如果 RPO 不允许，另行设计 StatefulSet + 每实例 RWO PVC + file_storage 持久队列，验证 drain/磁盘满/恢复，而不能给 Deployment 多副本共享一个 RWO PVC。持久化队列也不等于端到端 exactly-once。

默认不启用 Tail Sampling。未来启用必须在前置层按 trace ID 稳定路由至同一采样实例，并处理扩缩容路由变动/决策等待/迟到 span；普通 Service 负载均衡不能保证。敏感属性删除仅示例名单，业务还应在 SDK 源头避免 token、个人信息、SQL 参数进入 span/resource/event。必要时增加 transform/redaction 规则并验证自定义属性和异常文本。
