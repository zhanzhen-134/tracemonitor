"""Offline checks for consequential wiring mistakes; not a cluster acceptance test."""
from pathlib import Path
import json
import sys
import yaml

root=Path(__file__).resolve().parents[2]
docs=[d for d in yaml.safe_load_all((root/'build/tempo-rendered.yaml').read_text(encoding='utf-8')) if d]
workloads=[d for d in docs if d['kind'] in ['Deployment','StatefulSet']]
services={d['metadata']['name']:d for d in docs if d['kind']=='Service'}
cfg=next(yaml.safe_load(d['data']['tempo.yaml']) for d in docs if d['kind']=='ConfigMap' and 'tempo.yaml' in d.get('data',{}))
assert cfg['storage']['trace']['backend']=='s3'
assert cfg['ingest']['kafka']['auto_create_topic_enabled'] is False
assert cfg['cache']['caches']==[], 'Disabled cache must not reference absent Memcached'
assert cfg['overrides']['defaults']['metrics_generator']['processors']==['span-metrics','service-graphs']
assert cfg['storage']['trace']['s3']['secret_key']=='${MINIO_SECRET_KEY}'
for d in workloads:
    spec=d['spec']['template']['spec']
    for c in spec['containers']:
        if '/grafana/tempo:' not in c['image']:
            continue
        assert '-config.expand-env=true' in c['args'], d['metadata']['name']
        assert {'secretRef':{'name':'tempo-credentials'}} in c['envFrom'], d['metadata']['name']
        assert any(v.get('secret',{}).get('secretName')=='tempo-ca' for v in spec['volumes'])
        assert any(m['mountPath']=='/etc/tempo/ca' for m in c['volumeMounts'])
        assert c['resources']['requests'] and c['resources']['limits']
        assert c['startupProbe'] and c['readinessProbe'] and c['livenessProbe']
        assert not spec.get('automountServiceAccountToken',False)
for svc in services.values():
    selector=svc['spec'].get('selector',{})
    selected=[w for w in workloads if selector and all(w['spec']['template']['metadata']['labels'].get(k)==v for k,v in selector.items())]
    assert selected, f'Service selects no workload: {svc["metadata"]["name"]}'
    for port in svc['spec'].get('ports',[]):
        if isinstance(port.get('targetPort'),str):
            for w in selected:
                names={p['name'] for c in w['spec']['template']['spec']['containers'] for p in c.get('ports',[])}
                assert port['targetPort'] in names, f'{svc["metadata"]["name"]}: {port}'
mode=(root/'build/render-mode.txt').read_text()
live=[w for w in workloads if w['metadata']['name'].startswith('tempo-live-store')]
if mode=='production':
    assert len(live)==2
    assert sum(w['spec']['replicas'] for w in live)==6
    assert all(w['spec']['template']['spec']['nodeSelector']['topology.kubernetes.io/zone'] for w in live)
    assert any(d['kind']=='ZoneAwarePodDisruptionBudget' for d in docs)
else:
    assert len(live)==1 and live[0]['spec']['replicas']==1
assert next(w for w in workloads if w['metadata']['name']=='tempo-backend-scheduler')['spec']['replicas']==1
for path in (root/'build/manifests').rglob('*.yaml'):
    for d in yaml.safe_load_all(path.read_text(encoding='utf-8')):
        if d and d['kind']=='NetworkPolicy':
            for direction in ['ingress','egress']:
                for rule in d['spec'].get(direction,[]):
                    for port in rule.get('ports',[]):
                        assert isinstance(port['port'],int), (path,port)
json.loads((root/'build/integrations/grafana/tempo-overview.json').read_text())
print(f'PASS: {mode}, {len(workloads)} workloads; ports, selectors, Secret/CA, targets, cache, HA and policies checked')
