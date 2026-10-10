# 固定版本 Chart

`tempo-distributed-3.11.1.tgz` 是上游原始发布包，含锁定依赖。Tempo 3.1.0；rollout-operator Chart 0.52.0 / 镜像 v0.40.0。
生产 values 以 3 个 Kafka 分区、2 个可用区为示例（6 个 Live Store）。必须结合容量表调整。
开发覆盖文件必须在生产基础 values 后合并，仍然复用外部 Kafka/MinIO，使用独立测试 Topic/Bucket。
`values-dev.yaml` 不是生产配置。不得把开发 release 原地升级成生产多区部署。
包的 SHA256 见 versions.json；更换上游包必须重新核验、渲染、压测。
