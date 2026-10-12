# 本地验证报告

验证日期：2026-10-10。结果是可用于环境适配与预生产部署的交付包，**不是生产集群验收通过证明**。没有使用真实凭据，没有执行任何 kubectl/helm 写入集群的操作。

| 验证项 | 本次结果 |
|---|---|
| 官方版本与字段 | Chart 3.11.1（appVersion 3.1.0）；Tempo 3.1.0 固定 tag 配置；Operator v0.22.0 不适用 |
| Chart 文件 | 上游原始 tgz 含依赖，SHA256 记录于 charts/tempo/versions.json，渲染时校验一致 |
| Helm 3.19.0 lint + template | 生产、开发均通过；生产 10 个 Helm 工作负载对象，开发 8 个 |
| 生产架构 | 8 种 Tempo target，无 ingester/compactor；Live Store 两个 StatefulSet 合计 6 Pod；Scheduler 1 Pod |
| 连接与安全引用 | Service selector/具名 targetPort、Secret env、CA 挂载、config.expand-env、probes、资源值检查通过 |
| 缓存配置 | Memcached 未部署，cache.caches 为空，无悬空缓存服务引用 |
| Kubernetes schema | kubeconform 0.8.0、K8s 1.32.0 参考 schema：69 个资源，56 有效、0 无效、0 错误、13 跳过 |
| 跳过的 13 项 | 9 ServiceMonitor、1 PrometheusRule、1 ZoneAwarePodDisruptionBudget、2 CRD；必须在目标集群用实际 CRD 做 server dry-run |
| Collector 配置 | 官方 Windows otelcol-contrib 0.135.0 执行 validate 成功；未验证目标证书文件内容/握手 |
| PromQL 告警 | promtool 3.5.0 check rules：39 条规则语法通过；实际 series/labels/阈值需现场确认 |
| Bash / Python | 所有交付 Bash 脚本 bash -n 通过；Python compileall 通过 |
| Python SDK 烟雾测试 | verify_sdk.py 通过：入口父 context、HTTP 客户端传播、CLIENT/SERVER span、ERROR event、资源属性、结构化日志 ID |
| 负向保护 | 未替换占位符时 render 拒绝执行并清除成功标记；生产安装脚本拒绝开发 bundle |

开发配置修复了继承生产 noDownscale 的冲突；必须同时关闭 zoneAwareReplication 和 noDownscale。Chart 自身 lint 没有把该模板 fail 视作失败，因此交付流程始终同时执行 template，不能只依赖 lint。

示例 SDK 测试使用内存 exporter 和本机 HTTP 服务，不依赖 Tempo，并不证明完整生产链路。Python 依赖安装/测试运行在本机 Windows Python 3.14。目标运行版本为 Python 3.10.12：全部 Python 代码（含交互式脚本中的内联片段）已按 3.10 语法解析通过，未使用 3.11+ 标准库 API；`requirements.lock` 与 `scripts/tempo/requirements.txt` 的全部固定版本已用 `pip download --python-version 3.10` 确认存在 cp310 安装包。交付容器基于 `python:3.10.12-slim-bookworm`，Docker 构建及该运行时下的实际执行尚未进行。

## 尚待目标环境执行

- 真实 K8s 版本/CRD admission/CNI/PodSecurity/StorageClass 验证，rollout webhook 控制面可达性。
- Linux Tempo 3.1.0 全部 target 实际启动和配置解析、Kafka SCRAM/TLS/ACL、S3 证书/权限。
- SDK→Collector mTLS、内部受限明文链路安全基线评审、未知/非授权客户端阻断测试。
- 真实 Trace ID 的近期查询和 Querier backend-only 查询；Grafana Service Map、Exemplar、ES 双向关联。
- Prometheus receiver/selector/指标单位、告警触发恢复、现有 Kafka/MinIO 平台告警覆盖。
- 目标流量压测、单区故障、Kafka/MinIO/Remote Write 故障、恢复时间及丢失统计。
- 现有 Grafana/Prometheus/ELK/Kafka 版本与参数、镜像扫描和企业供应链审批。

以上验证使用 `.cache/smoke.json` 中的虚构示例地址生成本地 `build/`。为避免将测试渲染当作实际部署，最终移除了 build/render-mode.txt 成功标记；填写真实 environment.local.json 并重新 render 才能执行安装脚本。

复验入口：`python3 scripts/tempo/render.py environment.local.json` → `python3 scripts/tempo/check_rendered.py`。SDK 复验先安装 `examples/python-otel-demo/requirements.lock`，再执行 `python3 scripts/python-otel-demo/verify_sdk.py`。部署与验收顺序见 04、06，上线批准清单见 11。
