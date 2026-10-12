# 升级、扩缩容与回滚

升级前：固定新 Chart/Tempo/Collector 版本并核验发行说明；备份 `helm get values`、`helm get manifest`、Deployment/StatefulSet/ConfigMap/NetworkPolicy/CRD 版本与 Secret 引用。Secret 明文备份走企业密钥系统，不能进入 Git。保存 Kafka Topic 配置（retention 等）、RustFS bucket 状态和 Grafana provisioning；Kafka / RustFS 镜像升级按各自发行说明单独评审。先以真实协议在预生产回放代表性流量。

同小版本升级流程：下载新包并记录 hash→修改 versions 与 values→lint/template/diff→应用配置校验→预生产持久化+恢复验收→变更单→生产 `helm upgrade --install ... --wait`→观察一个完整 block 周期与长期查询。跨区 Live Store 由 rollout-operator 协调，PDB 不能约束直接删除 Pod；禁止同时滚动所有区。Tempo 3.1 vParquet5 默认写入，降级前核验目标版本读取能力；不能只改 image tag。

```bash
helm -n "$TEMPO_NAMESPACE" history tempo
helm -n "$TEMPO_NAMESPACE" get values tempo -o yaml > build/tempo-before.yaml
helm -n "$TEMPO_NAMESPACE" get manifest tempo > build/tempo-before-manifest.yaml
export REVISION='<数字>' ROLLBACK_COMPATIBILITY_APPROVAL='<兼容性评审记录>'
bash scripts/tempo/rollback.sh
```

Helm values 回滚只恢复受管理资源；镜像回退必须确认配置与 block/WAL/offset 兼容；跨大版本降级不默认支持；Kafka / RustFS 的数据恢复依赖其 PVC，是单独操作。CRD 不随普通 Helm rollback 回退。Collector 原生清单须从审核过的上一个版本重新 apply，ConfigMap 更新后 rollout restart；deployment rollout undo 不会恢复 ConfigMap 内容。

Kafka 扩容先评审分区数与路由、增加物理分区，再按 ordinal 增加所有 AZ 的 Live Store 和相应 Block Builder 覆盖。等 PENDING→ACTIVE、至少两个 owner、消费 lag 稳定后增加流量。默认 partitions_per_instance=1；该规则下每区 liveStore.replicas 与 builder.replicas 都匹配已启用分区数量，不能独立随意缩 builder。

消费者缩容默认被 noDownscale 拒绝。计划缩容时先在预生产验证 partition lifecycle API 与当前版本，人工停写目标 Tempo partition（INACTIVE），保持所有 owner 和 builder 运行，等待旧数据落 S3、后端查询可用、最近查询窗口过期，再依次移除目标 owner、最后移除无任务 builder。审批后按确切方案调整 noDownscale，不同时移除 zone 列表。Kafka 物理分区保留；若要减少物理分区，另建 Topic/新部署、双轨接入切换、排空旧数据后退役。不能执行不存在的 Kafka 原地减少分区命令。

变更保留期：先计算即时待删对象、评审恢复点和业务影响；缩短保留期可能不可逆删除。S3 lifecycle 与 Tempo retention 联合审核；回滚 values 无法找回已删除且未备份的对象。
灾备恢复：先恢复 Kafka 与 RustFS 的 PVC 数据和 tempo-credentials 密钥，再恢复 Namespace、CRD、Secret 引用、PVC 与原配置；停止不兼容写入，核验 partition offset 与可重放窗口，启动 scheduler/worker/消费端/查询端后验证历史 trace，再开放 SDK。单独恢复 offset 到错误位置可能跳过或重复数据，必须按备份的一致性点演练。
