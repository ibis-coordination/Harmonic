FROM python:3.12-slim

WORKDIR /app

# Install dependencies first for better caching
COPY pyproject.toml README.md ./
RUN pip install --no-cache-dir ".[dev]"

# Copy source code and tests
COPY src/ src/
COPY tests/ tests/

# Run the application
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
