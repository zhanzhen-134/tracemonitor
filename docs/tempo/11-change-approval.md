# 上线变更清单

本仓库已完成文件准备；以下审批发生在实际发布前，由平台负责人记录单号。不是要求为本地文件编辑另行审批。

| 变更 | 影响与评审重点 | 执行者/恢复 |
|---|---|---|
| Namespace、工作负载、PVC、NetworkPolicy | 资源配额、两 AZ 调度、DNS/CNI、内部明文通道符合基线 | SRE；回退清单，保留 PVC |
| rollout-operator CRD/RBAC/webhook | 集群级 API/准入资源；仅目标 namespace 的滚动/驱逐保护；已有安装的所有权 | K8s 平台；先恢复 webhook 服务，不直接删除保护 |
| Kafka 新 Topic/ACL | RF/ISR、磁盘、16000000 字节消息、消费组与共享 broker fetch 限制 | Kafka 平台；停入口、排空后退役，不能回滚已过期数据 |
| MinIO Bucket/账号/policy | 容量、EC/复制、生命周期、证书和删除权限 | 存储平台；恢复账号/策略，删除数据依赖备份 |
| Prometheus receiver/selector/exemplar | 新写入负载、TSDB 基数、安全访问、监控对象发现 | 监控平台；先停 generator 写入，再恢复原 values |
| Grafana 新 Tempo 数据源/ES Data links | UID 冲突、查询权限、版本支持、Provisioning 归属 | Grafana 平台；恢复原数据源定义 |
| ES mapping/log pipeline | keyword/date 类型、现有字段冲突、索引保留 | ELK 平台；必要时新索引切换，不破坏原日志链路 |
| 应用 namespace 标签/SDK/client cert | 哪些 namespace 可以接入、敏感属性、采样、客户端证书发放 | 业务负责人；撤销接入权限/回退 SDK 配置 |

生产发布准入证据：实际环境兼容性表、SLO/RPO/RTO、证书/ACL 测试、server dry-run、Tempo 全 target 启动、近期及后端 Trace ID 验收、指标/日志关联、压测和故障演练。未通过时保持为部署候选，不宣称生产就绪。
