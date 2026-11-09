FROM python:3.11-slim

WORKDIR /app

# 使用清华 PyPI 镜像，避免国内环境拉包超时
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    -i https://pypi.tuna.tsinghua.edu.cn/simple

COPY app.py .

EXPOSE 8000
CMD ["python", "app.py"]
