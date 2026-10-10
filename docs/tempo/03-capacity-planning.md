# 容量估算与压测计划

这些数字是算例，不是已确认的生产容量。把峰值、平均值分别记录，不能用峰值全天计费后声称是准确预测。

| 输入 | 算例 | 上线前填写 |
|---|---:|---|
| 平均 / 峰值 spans/s（采样前） | 10000 / 30000 | 待压测 |
| 平均序列化 span 大小 | 1000 B | 从真实 payload 测量 |
| head sampling 比例 | 20% | 按业务及服务图完整性决定 |
| Kafka 保留 | 24h | 大于最大故障+追平时间+余量 |
| Tempo 对象保留 | 30d | 业务/合规确认 |
| Kafka 压缩比 / S3 压缩比 | 0.5 / 0.3 | 数据决定，不能照搬 |
| Query QPS / 并发 | 10 / 20 | 含长时间 TraceQL 查询 |
| AZ | 2 | 若仅 1 AZ，不具备故障域 HA |
| 节点 CPU / RAM / 可分配比例 | 待填 | 预留 kube/system 与升级 surge |
| 指标 label 组合 / scrape interval | 待测 / 15s 派生指标 | 不加入 user_id、trace_id 等高基数字段 |

入口平均字节率 R = spans/s × span_bytes × sampling。本例平均 2 MB/s、峰值 6 MB/s（十进制）。SDK head sampling 使用 ParentBased + TraceIdRatioBased，跨服务继承采样决策；不要在每层独立随机采样。

Kafka 原始逻辑数据 = R × retention_seconds × 压缩比；磁盘预算再乘 RF 和至少 1.3 余量。本例 2e6 × 86400 × 0.5 × 3 × 1.3 ≈ 337 GB，不含索引与 segment 开销。一个 broker 故障后 ISR>=2、补副本和 catch-up I/O 必须仍可支撑峰值。

MinIO 逻辑对象 = R × 86400 × days × S3 压缩比 × 1.3。本例约 2.02 TB；物理磁盘再按 MinIO erasure coding/replication 开销计算，包含 compaction 临时双份、版本历史、跨站复制和删除延迟。不要重复将 EC 与 3 副本同时相乘，按实际拓扑算。

Tempo CPU/内存不能从字节率直接推导。每个 Block Builder 的 scratch 至少容纳一个完整 consume cycle 的数据与峰值临时编码空间。Live Store 内存约为单分区采样后速率 × 最近窗口 × 展开系数，加索引与查询空间；跨区复制会使总占用增加。生产 values 的 4Gi request/8Gi limit 是初始压测值。压测观测 RSS、GC、Kafka lag、S3 请求与查询 p95 后调整，保留单 AZ 故障容量。

Prometheus 系列数 ≈ 服务 × operation/span_name × span_kind × status × 额外维度组合 × histogram 系列数，加服务边组合。经典 histogram 每组约 bucket_count+3 系列（含 +Inf、sum、count）。写入样本/s≈活跃系列数/collection_interval。磁盘≈样本/s×每样本实测字节×保留秒数，再加 WAL/head/churn 余量。先启用少量服务，测 TSDB head、ingest latency、dropped samples；不得无评估将几十万新系列灌入共享 Prometheus。

分区算例 3，Block Builder partitions_per_instance=1，因此 3 builder；每区 3 live-store，共 6 个。不能按 9 个消费者就建 9 个分区。更换分配方式必须覆盖全部 ACTIVE partition 且无重复 builder 所有权。Metrics Generator 使用消费组重平衡，副本数独立于其他组件，但有效并行度受分区数约束。

压测按 25%→50%→100%→150% 峰值递增，每阶段至少覆盖一个 block 构建周期；并发施加真实查询。记录入口成功/拒绝、queue、lag 秒数、对象写入、CPU/RSS、查询 p50/p95/p99、Remote Write 与指标基数。再做单节点/单区故障。设定允许的 RPO/RTO 后再批准资源、Retention、HPA 最大值。禁止让未知流量触发 Live Store/Block Builder 通用 HPA 缩容。
