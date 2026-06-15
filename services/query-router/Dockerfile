FROM python:3.12-alpine
WORKDIR /app
COPY services/common /app/common
COPY services/query-router/main.py /app/main.py
ENV PYTHONUNBUFFERED=1
CMD ["python", "/app/main.py"]
