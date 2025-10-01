FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends cups-client && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY backend/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/app.py /app/app.py
ENV PYTHONUNBUFFERED=1 \
    UPLOAD_DIR=/data/uploads
RUN mkdir -p /data/uploads
VOLUME ["/data/uploads"]
EXPOSE 3000
CMD ["python", "app.py"]
