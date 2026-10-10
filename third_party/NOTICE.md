# Upstream material

- `charts/tempo/tempo-distributed-3.11.1.tgz`: unmodified Grafana Community Helm chart release, including its bundled dependencies. Source: https://github.com/grafana-community/helm-charts/releases/tag/tempo-distributed-3.11.1 . Retain upstream notices and dependency licenses when redistributing.
- `manifests/tempo/prometheusrule.yaml`: Tempo alert groups adapted from https://github.com/grafana/tempo/blob/v3.1.0/operations/tempo-mixin-compiled/alerts.yaml . Changes: namespace isolation, removal of disabled optional component alerts, addition of Collector/Kubernetes alerts. Grafana Tempo is licensed under GNU AGPL v3; full upstream license is in `third_party/tempo/LICENSE`.
