# PR Security Bot - SAST scanner image (Deeyan)
FROM python:3.12-slim

# git to clone the PR, ca-certificates for HTTPS to GitHub/S3
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY scan.py .

# Untrusted PR code is handled by a non-root user
RUN useradd --create-home scanner
USER scanner

ENTRYPOINT ["python", "/app/scan.py"]
