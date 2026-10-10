"""Render non-secret environment parameters. Run from any working directory."""
import argparse
import hashlib
import json
import re
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
    if any('<' in str(v) or not str(v).strip() for v in env.values()):
        raise SystemExit('Replace all environment placeholders before rendering')
    if not re.fullmatch(r'[a-z0-9]([-a-z0-9]*[a-z0-9])?', env['TEMPO_NAMESPACE']):
        raise SystemExit('Invalid Kubernetes namespace')
    if env['KAFKA_SASL_MECHANISM'] not in ['PLAIN', 'SCRAM-SHA-256', 'SCRAM-SHA-512']:
        raise SystemExit('Select supported PLAIN or SCRAM mechanism; TLS remains enabled')
    if env['ZONE_A'] == env['ZONE_B'] and not args.dev:
        raise SystemExit('Production requires two distinct availability zones')
    for key in ['KAFKA_PORT','MINIO_PORT','PROMETHEUS_PORT']:
        if not isinstance(env[key], int) or not 0 < env[key] < 65536:
            raise SystemExit(f'{key} must be an integer port')
    files = [ROOT/'charts/tempo/values-production.yaml']
    files += list((ROOT/'manifests').rglob('*.yaml'))
    files += list((ROOT/'integrations').rglob('*.yaml'))
    for path in files:
        if path.name == 'secret.example.yaml':
            continue
        docs = [substitute(d, env) for d in yaml.safe_load_all(path.read_text(encoding='utf-8'))]
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
    print(f'Rendered {len(workloads)} workloads to {out}; no cluster changes made')

if __name__ == '__main__':
    main()
