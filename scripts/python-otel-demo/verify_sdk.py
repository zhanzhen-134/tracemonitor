"""Verify SDK spans, HTTP context propagation, exception spans and JSON log IDs.

Uses an in-memory exporter and a loopback HTTP server. No production backend is contacted.
"""
import importlib
import io
import json
import os
from pathlib import Path
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import SpanKind, StatusCode

class Downstream(BaseHTTPRequestHandler):
    def do_GET(self):
        header = self.headers.get('traceparent', '')
        trace_id = header.split('-')[1] if header else ''
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'trace_id':trace_id}).encode())
    def log_message(self, *args):
        pass

server=HTTPServer(('127.0.0.1',0),Downstream)
thread=threading.Thread(target=server.serve_forever,daemon=True)
thread.start()
os.environ['DOWNSTREAM_URL']=f'http://127.0.0.1:{server.server_port}/work'
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'examples/python-otel-demo'))
exporter=InMemorySpanExporter()
try:
    with patch('opentelemetry.exporter.otlp.proto.grpc.trace_exporter.OTLPSpanExporter',return_value=exporter):
        demo=importlib.import_module('app')
    logs=io.StringIO()
    demo.handler.setStream(logs)
    client=demo.app.test_client()
    parent='0123456789abcdef0123456789abcdef'
    response=client.get('/call',headers={'traceparent':f'00-{parent}-1234567890abcdef-01'})
    assert response.status_code==200,response.data
    assert response.json['trace_id']==response.json['downstream']['trace_id']==parent
    error=client.get('/error')
    assert error.status_code==500
    assert demo.provider.force_flush(timeout_millis=5000)
    spans=exporter.get_finished_spans()
    assert any(s.kind==SpanKind.CLIENT and s.context.trace_id==int(parent,16) for s in spans)
    assert any(s.kind==SpanKind.SERVER for s in spans)
    assert any(s.status.status_code==StatusCode.ERROR and s.events for s in spans)
    assert all(s.resource.attributes['service.version']=='1.0.0' for s in spans)
    entries=[json.loads(line) for line in logs.getvalue().splitlines()]
    assert any(e['trace_id']==parent and len(e['span_id'])==16 for e in entries)
    print('PASS: HTTP propagation, incoming parent, CLIENT/SERVER spans, ERROR event, resource attributes and JSON logs')
finally:
    server.shutdown()
    server.server_close()
