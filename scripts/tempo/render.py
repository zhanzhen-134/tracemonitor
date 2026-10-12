"""Render non-secret environment parameters. Run from any working directory."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[2]
TOKEN = re.compile(r'<([A-Z][A-Z0-9_]*)>')

def substitute(value, env):
    if isinstance(value, dict):
        return {k: substitute(v, env) for k, v in value.items()}
    if isinstance(value, list):
        return [substitute(v, env) for v in value]
    if isinstance(value, str):
        exact = TOKEN.fullmatch(value)
        if exact:
            return env[exact[1]]
        return TOKEN.sub(lambda m: str(env[m[1]]), value)
    return value

def merge(base, overlay):
    for k, v in overlay.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            merge(base[k], v)
        else:
            base[k] = v
    return base

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('environment', type=Path)
    parser.add_argument('--helm', default='helm')
    parser.add_argument('--dev', action='store_true')
    args = parser.parse_args()
    out = ROOT/'build'
    out.mkdir(exist_ok=True)
    (out/'render-mode.txt').unlink(missing_ok=True)
    if Path(args.helm).is_file():
        args.helm = str(Path(args.helm).resolve())
    env = json.loads(args.environment.read_text(encoding='utf-8-sig'))
    expected = json.loads((ROOT/'environment.example.json').read_text(encoding='utf-8-sig'))
    missing = sorted(set(expected) - set(env))
    if missing:
        raise SystemExit(f'Missing parameters (compare with environment.example.json): {", ".join(missing)}')
    # The demo is optional: leave DEMO_NAMESPACE and DEMO_IMAGE empty to skip rendering it.
    demo_keys = ['DEMO_NAMESPACE', 'DEMO_IMAGE']
    skip_demo = all(not str(env.get(k, '')).strip() for k in demo_keys)
    # Zones are optional: both empty = single-zone; both set = zone-aware live-store + rollout-operator.
    zone_keys = ['ZONE_A', 'ZONE_B']
    zones_set = [bool(str(env.get(k, '')).strip()) for k in zone_keys]
    if any(zones_set) and not all(zones_set):
        raise SystemExit('Set both ZONE_A and ZONE_B for multi-zone, or leave both empty for single-zone')
    multi_zone = all(zones_set)
    optional = (demo_keys if skip_demo else []) + ([] if multi_zone else zone_keys)
    if any('<' in str(v) or not str(v).strip() for k, v in env.items() if k not in optional):
        raise SystemExit('Replace all environment placeholders before rendering')
    if not re.fullmatch(r'[a-z0-9]([-a-z0-9]*[a-z0-9])?', env['TEMPO_NAMESPACE']):
        raise SystemExit('Invalid Kubernetes namespace')
    if multi_zone and env['ZONE_A'] == env['ZONE_B']:
        raise SystemExit('ZONE_A and ZONE_B must be different availability zones')
    if not isinstance(env['PROMETHEUS_PORT'], int) or not 0 < env['PROMETHEUS_PORT'] < 65536:
        raise SystemExit('PROMETHEUS_PORT must be an integer port')
    for key in ['KAFKA_STORAGE_SIZE', 'RUSTFS_STORAGE_SIZE']:
        if not re.fullmatch(r'[1-9][0-9]*(Gi|Ti)', str(env[key])):
            raise SystemExit(f'{key} must be a size such as 100Gi or 1Ti')
    files = [ROOT/'charts/tempo/values-production.yaml']
    files += list((ROOT/'manifests').rglob('*.yaml'))
    files += list((ROOT/'integrations').rglob('*.yaml'))
    demo_dir = ROOT/'manifests/python-otel-demo'
    if skip_demo:
        shutil.rmtree(out/demo_dir.relative_to(ROOT), ignore_errors=True)
    for path in files:
        if path.name == 'secret.example.yaml':
            continue
        if skip_demo and demo_dir in path.parents:
            continue
        docs = [substitute(d, env) for d in yaml.safe_load_all(path.read_text(encoding='utf-8'))]
        if multi_zone and path.name == 'values-production.yaml':
            overlay = yaml.safe_load((ROOT/'charts/tempo/values-multi-zone.yaml').read_text(encoding='utf-8'))
            docs = [merge(docs[0], substitute(overlay, env))]
        target = out/path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(yaml.safe_dump_all(docs, sort_keys=False, allow_unicode=True), encoding='utf-8')
    for path in (ROOT/'integrations').rglob('*.json'):
        target = out/path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        data = substitute(json.loads(path.read_text(encoding='utf-8')), env)
        target.write_text(json.dumps(data, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
    chart = ROOT/'charts/tempo/tempo-distributed-3.11.1.tgz'
    lock = json.loads((ROOT/'charts/tempo/versions.json').read_text())
    if hashlib.sha256(chart.read_bytes()).hexdigest() != lock['sha256']:
        raise SystemExit('Chart checksum mismatch')
    flags = ['-f', str(out/'charts/tempo/values-production.yaml')]
    if args.dev:
        flags += ['-f', str(ROOT/'charts/tempo/values-dev.yaml')]
    subprocess.run([args.helm, 'lint', str(chart), *flags], check=True)
    result = subprocess.run([args.helm,'template','tempo',str(chart),'-n',env['TEMPO_NAMESPACE'],
                             '--include-crds',*flags], check=True, capture_output=True, text=True, encoding='utf-8')
    (out/'tempo-rendered.yaml').write_text(result.stdout, encoding='utf-8')
    workloads = [d for d in yaml.safe_load_all(result.stdout) if d and d.get('kind') in ['Deployment','StatefulSet']]
    targets = {a.split('=',1)[1] for d in workloads for c in d['spec']['template']['spec']['containers']
               for a in c.get('args',[]) if a.startswith('-target=')}
    required = {'distributor','live-store','block-builder','backend-scheduler','backend-worker','querier','query-frontend','metrics-generator'}
    if not required <= targets or targets & {'ingester','compactor'}:
        raise SystemExit(f'Unexpected Tempo targets: {targets}')
    for d in workloads:
        for c in d['spec']['template']['spec']['containers']:
            if c['image'].endswith(':latest') or ':' not in c['image']:
                raise SystemExit(f'Unpinned image: {c["image"]}')
    (out/'render-mode.txt').write_text('dev' if args.dev else 'production')
    (out/'zone-mode.txt').write_text('multi' if multi_zone else 'single')
    print(f'Rendered {len(workloads)} workloads ({"multi" if multi_zone else "single"}-zone) to {out}; no cluster changes made')

if __name__ == '__main__':
    main()
