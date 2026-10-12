# 上线变更清单

本仓库已完成文件准备；以下变更全部由安装执行人按 [04-installation.md](04-installation.md) 操作，执行前取得审批并记录单号。不是要求为本地文件编辑另行审批。

| 变更 | 影响与评审重点 | 恢复方式 |
|---|---|---|
| Namespace、工作负载、PVC、NetworkPolicy | 资源配额、两 AZ 调度、DNS/CNI、内部明文通道符合基线 | 回退清单，保留 PVC |
| rollout-operator CRD/RBAC/webhook（仅双可用区模式） | 集群级 API/准入资源；仅目标 namespace 的滚动/驱逐保护；已有安装的所有权 | 先恢复 webhook 服务，不直接删除保护 |
| Kafka 新 Topic/ACL | RF/ISR、磁盘、16000000 字节消息、消费组与共享 broker fetch 限制 | 停入口、排空后退役，不能回滚已过期数据 |
| MinIO Bucket/账号/policy | 容量、EC/复制、生命周期、证书和删除权限 | 恢复账号/策略，删除数据依赖备份 |
| Prometheus receiver/selector/exemplar | 新写入负载、TSDB 基数、安全访问、监控对象发现 | 先停 generator 写入，再恢复原 values |
| Grafana 新 Tempo 数据源/ES Data links | UID 冲突、查询权限、版本支持、Provisioning 归属 | 恢复原数据源定义 |
| ES mapping/log pipeline | keyword/date 类型、现有字段冲突、索引保留 | 必要时新索引切换，不破坏原日志链路 |
| 应用 namespace 标签/SDK/client cert | 哪些 namespace 可以接入、敏感属性、采样、客户端证书发放 | 撤销接入权限/回退 SDK 配置 |
| OpenTelemetry Operator CRD/RBAC/webhook | 集群级准入资源；Pod 注入 webhook 为 Ignore，故障时不阻塞建 Pod；已有安装的所有权；agent 镜像同步 | 先移除业务注解，再 helm uninstall，CRD 评估后删除 |
| otel-gateway 明文 4319 入口 | 集群内明文 OTLP/HTTP，仅放行 `tracing-access=enabled` namespace；需符合安全基线 | 从 pipeline 移除 otlp/plaintext 并重启 gateway |
| 业务 Deployment 注入注解 | 触发滚动重启；内存/启动时间增加；与已有 Java agent 冲突；采样 20% | 删除注解并滚动重启 |

生产发布准入证据：实际环境兼容性表、SLO/RPO/RTO、证书/ACL 测试、server dry-run、Tempo 全 target 启动、近期及后端 Trace ID 验收、指标/日志关联、压测和故障演练。未通过时保持为部署候选，不宣称生产就绪。
