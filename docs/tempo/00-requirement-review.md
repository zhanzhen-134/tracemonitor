# 需求审查与实施决策

审查日期：2026-10-10。结论：目标、数据路径和复用边界合理，可以实施；以下约束按本文件解释。

| 原要求 | 审查结论与处理 |
|---|---|
| Tempo 3.1 或更新稳定版 | 本次固定 Tempo 3.1.0、tempo-distributed 3.11.1；不用漂移版本 |
| Kafka 来源 | 需求原为接入现有 Kafka / MinIO。实施方案调整为在 Tempo namespace 内新建专用单节点 Kafka（apache/kafka 4.3.1，KRaft）和 RustFS（S3 兼容），与业务隔离；集群内明文、靠 NetworkPolicy 限制访问 |
| Operator | 核验最新正式 Tempo Operator v0.22.0 仍使用 Tempo 2.10.8，管理旧架构；不采用 |
| 主要组件多副本 | Backend Scheduler 官方规定单实例；PVC + K8s 重建恢复，维护任务可能短暂停顿 |
| Live Store 多副本 | 单区 3 Pod 各持有不同分区，不等于同分区 HA。本方案每区每分区一个副本 |
| 新增组件边界 | Live Store 跨区滚动/驱逐保护依赖 rollout-operator，不是 Tempo Operator；单独评审 CRD/webhook 权限 |
| Kafka 分区安全缩容 | Kafka Topic 分区不能原地减少。可停用 Tempo partition 并缩消费者，物理分区保留；需减少物理分区时新建 Topic 迁移 |
| 生产可直接使用 | 参数缺失时交付可渲染模板；实际证书、SLO、容量、兼容性与集群验收是上线条件 |
| Prometheus Receiver | 需验证现有版本/CRD，再以最小变更启用；不覆盖既有 values |
| 消息大小 | 专用 Kafka 的 broker 与 Topic max.message.bytes 均为 16000000 |
| 目录结构 | 按用户补充，K8s 清单在 manifests/<项目>，Helm 包在 charts/<项目>，脚本在 scripts/<项目> |

没有部署任何现有或新增集群服务。所有共享设施的变更由平台负责人审批执行。来源与固定版本链接见 [前置条件](02-prerequisites.md)。
