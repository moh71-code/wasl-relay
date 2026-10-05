FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY relay_server.py .

ENV PORT=8080
EXPOSE 8080

CMD uvicorn relay_server:app --host 0.0.0.0 --port $PORT
