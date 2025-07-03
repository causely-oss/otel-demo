FROM python:3.13-alpine

# Set working directory
WORKDIR /app

# Copy requirements and install Python dependencies
COPY ../requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy the Python scripts
COPY *.py ./

# Make scripts executable
RUN chmod +x chaos-scheduler.py toggle-flags.py

# Default command shows usage help
CMD ["python", "chaos-scheduler.py", "--help"] 