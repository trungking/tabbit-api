FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.docker.txt ./
RUN python -m pip install --upgrade pip \
    && python -m pip install -r requirements.docker.txt

COPY tabbit_client.py openai_server.py ./

EXPOSE 8000

CMD ["python", "openai_server.py", "--host", "0.0.0.0", "--port", "8000"]
