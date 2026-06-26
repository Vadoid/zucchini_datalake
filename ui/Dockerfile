# Explicit image for the Sync Control Panel. We build with `gcloud builds submit`
# (Docker) rather than `gcloud run deploy --source` (buildpacks) because the
# buildpack path reads a Google-managed runtimes-experiment config that 403s on
# older gcloud SDKs.
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

ENV PORT=8080
CMD ["sh", "-c", "uvicorn app:app --host 0.0.0.0 --port ${PORT:-8080}"]
