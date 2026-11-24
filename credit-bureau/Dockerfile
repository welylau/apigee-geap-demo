# Cymbal Credit Bureau (mock third-party MCP server) - stdlib only, no pip install.
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOST=0.0.0.0 \
    PORT=8080

WORKDIR /app
COPY server.py /app/server.py

# Run as an unprivileged user.
RUN useradd --system --uid 10001 --no-create-home bureau
USER 10001

EXPOSE 8080
CMD ["python", "/app/server.py"]
