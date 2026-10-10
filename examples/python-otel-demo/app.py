import atexit
import json
import logging
import os
from datetime import datetime, timezone
import requests
from flask import Flask, jsonify
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode

service = os.environ.get('OTEL_SERVICE_NAME', 'demo-a')
environment = os.environ.get('DEPLOYMENT_ENVIRONMENT', 'test')
provider = TracerProvider(resource=Resource.create({
    'service.name': service,
    'service.version': '1.0.0',
    'deployment.environment': environment,
    'deployment.environment.name': environment,
}))
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
atexit.register(provider.shutdown)

class JsonFormatter(logging.Formatter):
    def format(self, record):
        ctx = trace.get_current_span().get_span_context()
        return json.dumps({'@timestamp': datetime.now(timezone.utc).isoformat(),
            'level': record.levelname, 'message': record.getMessage(),
            'trace_id': f'{ctx.trace_id:032x}', 'span_id': f'{ctx.span_id:016x}',
            'service': {'name': service}, 'deployment': {'environment': environment}})

handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logger = logging.getLogger('demo')
logger.addHandler(handler)
logger.setLevel(logging.INFO)
logger.propagate = False
app = Flask(__name__)
FlaskInstrumentor().instrument_app(app, excluded_urls='healthz')
RequestsInstrumentor().instrument()

@app.get('/healthz')
def health():
    return 'ok'

@app.get('/work')
def work():
    logger.info('handling work')
    return jsonify(service=service, trace_id=f'{trace.get_current_span().get_span_context().trace_id:032x}')

@app.get('/call')
def call():
    response = requests.get(os.environ.get('DOWNSTREAM_URL', 'http://demo-b:8080/work'), timeout=5)
    response.raise_for_status()
    logger.info('downstream request complete')
    return jsonify(trace_id=f'{trace.get_current_span().get_span_context().trace_id:032x}', downstream=response.json())

@app.get('/error')
def error():
    try:
        raise RuntimeError('intentional acceptance-test error')
    except RuntimeError as exc:
        span = trace.get_current_span()
        span.record_exception(exc)
        span.set_status(Status(StatusCode.ERROR, str(exc)))
        logger.error('intentional failure')
        return jsonify(error=str(exc), trace_id=f'{span.get_span_context().trace_id:032x}'), 500
