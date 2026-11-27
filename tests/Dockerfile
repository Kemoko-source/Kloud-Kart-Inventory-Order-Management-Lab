# Exact version, so every rebuild of the test image is identical.
FROM python:3.12.16-slim
COPY tests/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
