#!/bin/bash
set -e

# Configuration
WORKSPACE_DIR="/workspace/ragflow"
REPO_DIR="$(pwd)"
VENV_DIR="$WORKSPACE_DIR/venv"
DATA_DIR="$WORKSPACE_DIR/data"
LOG_DIR="$WORKSPACE_DIR/logs"
CONF_DIR="$WORKSPACE_DIR/conf"
BIN_DIR="$WORKSPACE_DIR/bin"
WEB_DIST_DIR="$WORKSPACE_DIR/web_dist"

# Export paths
export PATH="$BIN_DIR:$VENV_DIR/bin:$PATH"
export PYTHONPATH="$REPO_DIR"
# Append to LD_LIBRARY_PATH instead of overwrite
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu/:$LD_LIBRARY_PATH

# Functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

setup_directories() {
    log "Creating directories..."
    mkdir -p "$DATA_DIR"/{mysql,redis,minio,infinity/wal,infinity/data}
    mkdir -p "$LOG_DIR"
    mkdir -p "$CONF_DIR"
    mkdir -p "$BIN_DIR"
    mkdir -p "$WEB_DIST_DIR"
}

install_dependencies() {
    log "Installing system dependencies..."
    apt-get update
    # Explicitly install python3.12 if available, or just python3
    apt-get install -y build-essential curl wget git nginx mysql-server redis-server \
        python3-dev python3-pip pkg-config libicu-dev libgdiplus default-jdk \
        libatk-bridge2.0-0 libgtk-4-1 libnss3 xdg-utils libgbm-dev libjemalloc-dev libssl-dev \
        unzip

    # Try to install python3.12 specifically if possible (common in newer ubuntu or deadsnakes PPA),
    # but rely on default python3 if 3.12 isn't strictly available in default repos without PPA.
    # RAGFlow requires >=3.10.

    # Install Node.js
    if ! command -v node &> /dev/null; then
        log "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi

    # Install uv
    if ! command -v uv &> /dev/null; then
        log "Installing uv..."
        pip install uv --break-system-packages
    fi

    # Install MinIO
    if [ ! -f "$BIN_DIR/minio" ]; then
        log "Downloading MinIO..."
        wget -q -O "$BIN_DIR/minio" https://dl.min.io/server/minio/release/linux-amd64/minio
        chmod +x "$BIN_DIR/minio"
    fi

    # Install Infinity Vector DB
    if ! command -v infinity &> /dev/null; then
        log "Installing Infinity Vector DB..."
        INFINITY_DEB="/tmp/infinity.deb"
        # Download deb
        wget -q -O "$INFINITY_DEB" https://github.com/infiniflow/infinity/releases/download/v0.6.15/infinity-0.6.15-x86_64.deb || \
        wget -q -O "$INFINITY_DEB" https://github.com/infiniflow/infinity/releases/download/v0.6.15/infinity_0.6.15_linux_amd64.deb

        dpkg -i "$INFINITY_DEB" || apt-get install -f -y
        rm -f "$INFINITY_DEB"
    fi
}

setup_python() {
    log "Setting up Python environment..."
    if [ ! -d "$VENV_DIR" ]; then
        # Use default python3
        uv venv "$VENV_DIR"
    fi

    # Activate venv
    source "$VENV_DIR/bin/activate"

    log "Installing Python packages..."
    uv pip install -r pyproject.toml

    # Install infinity-emb for embedding server (TEI replacement)
    log "Installing infinity-emb for embeddings..."
    uv pip install "infinity-emb[all]"

    # Run download_deps
    log "Downloading models and dependencies..."
    python3 download_deps.py
}

build_frontend() {
    log "Building frontend..."
    if [ ! -f "$WEB_DIST_DIR/index.html" ]; then
        cd "$REPO_DIR/web"
        npm install
        npm run build
        cp -r dist/* "$WEB_DIST_DIR/"
        cd "$REPO_DIR"
    fi
}

configure_services() {
    log "Configuring services..."

    # MySQL
    if [ ! -d "$DATA_DIR/mysql/mysql" ]; then
        log "Initializing MySQL data directory..."
        service mysql stop || true
        rm -rf "$DATA_DIR/mysql/*"

        # Ensure run directory exists
        mkdir -p /var/run/mysqld
        chown mysql:mysql /var/run/mysqld

        mysqld --initialize-insecure --user=mysql --datadir="$DATA_DIR/mysql"
    fi

    # .env
    if [ ! -f "$CONF_DIR/.env" ]; then
        cp "$REPO_DIR/docker/.env" "$CONF_DIR/.env"
        sed -i 's/DOC_ENGINE=elasticsearch/DOC_ENGINE=infinity/g' "$CONF_DIR/.env"
    fi

    # service_conf.yaml
    if [ ! -f "$CONF_DIR/service_conf.yaml" ]; then
        python3 - <<EOF
import os
import re

template_path = '$REPO_DIR/docker/service_conf.yaml.template'
output_path = '$CONF_DIR/service_conf.yaml'

try:
    with open(template_path, 'r') as f:
        content = f.read()

    def replace(match):
        var_name = match.group(1)
        default_val = match.group(2)
        if var_name in ['MYSQL_HOST', 'MINIO_HOST', 'REDIS_HOST', 'INFINITY_HOST', 'RAGFLOW_HOST', 'TEI_HOST', 'RERANK_HOST']:
            return '127.0.0.1'
        return default_val

    # Replace variable defaults
    content = re.sub(r'\$\{([^:}]+):-([^}]+)\}', replace, content)
    # Replace remaining variables with environment values
    content = re.sub(r'\$\{([^:}]+)\}', lambda m: os.environ.get(m.group(1), ''), content)

    # FIX: Update TEI port to 6380
    # The template has: base_url: 'http://${TEI_HOST}:80'
    # After substitution it becomes: base_url: 'http://127.0.0.1:80'
    # We need to change :80 to :6380 for TEI configuration
    content = content.replace("http://127.0.0.1:80", "http://127.0.0.1:6380")

    with open(output_path, 'w') as f:
        f.write(content)
except Exception as e:
    print(f"Error generating config: {e}")
    exit(1)
EOF
    fi

    rm -f "$REPO_DIR/conf/service_conf.yaml"
    ln -s "$CONF_DIR/service_conf.yaml" "$REPO_DIR/conf/service_conf.yaml"

    # Nginx
    log "Configuring Nginx..."
    cat > /etc/nginx/sites-available/ragflow <<EOF
server {
    listen 80 default_server;
    server_name _;
    root $WEB_DIST_DIR;
    index index.html;

    gzip on;
    gzip_min_length 1k;
    gzip_comp_level 9;
    gzip_types text/plain application/javascript application/x-javascript text/css application/xml text/javascript application/x-httpd-php image/jpeg image/gif image/png;
    gzip_vary on;

    location ~ ^/api/v1/admin {
        proxy_pass http://127.0.0.1:9381;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location ~ ^/(v1|api) {
        proxy_pass http://127.0.0.1:9380;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/ragflow /etc/nginx/sites-enabled/ragflow
}

start_services() {
    log "Starting services..."

    # Load env vars
    set -a
    source "$CONF_DIR/.env"
    set +a

    # MySQL
    if ! pgrep mysqld > /dev/null; then
        mkdir -p /var/run/mysqld
        chown mysql:mysql /var/run/mysqld

        mysqld --user=mysql --datadir="$DATA_DIR/mysql" > "$LOG_DIR/mysql.log" 2>&1 &
        log "Waiting for MySQL to start..."
        sleep 10
        mysql -S /var/run/mysqld/mysqld.sock -u root -e "CREATE DATABASE IF NOT EXISTS rag_flow; CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY 'infini_rag_flow'; GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;" || true
        mysql -S /var/run/mysqld/mysqld.sock -u root -pinfini_rag_flow rag_flow < "$REPO_DIR/docker/init.sql" || true
    fi

    # Redis
    if ! pgrep redis-server > /dev/null; then
        redis-server --dir "$DATA_DIR/redis" --daemonize yes
    fi

    # MinIO
    if ! pgrep minio > /dev/null; then
        MINIO_ROOT_USER=rag_flow MINIO_ROOT_PASSWORD=infini_rag_flow "$BIN_DIR/minio" server "$DATA_DIR/minio" --address ":9000" --console-address ":9001" > "$LOG_DIR/minio.log" 2>&1 &
    fi

    # Infinity
    if ! pgrep infinity > /dev/null; then
        cat > "$CONF_DIR/infinity_conf.toml" <<EOF
[general]
cpu_limit = 4
version = "0.6.15"
timezone = "UTC"

[network]
server_address = "0.0.0.0"
postgres_port = 5432
http_port = 23820
client_port = 23817
connection_limit = 512

[log]
log_dir = "$LOG_DIR/infinity"
log_filename = "infinity.log"
log_to_stdout = false
log_max_size = 1073741824
log_rotate_count = 8
log_level = "info"

[buffer]
buffer_size = "4GB"

[wal]
wal_dir = "$DATA_DIR/infinity/wal"
wal_compact_threshold = "1GB"
full_checkpoint_interval = 86400
delta_checkpoint_interval = 60
delta_checkpoint_threshold = "1GB"

[storage]
data_dir = "$DATA_DIR/infinity/data"
default_row_size = 8192
EOF
        infinity -f "$CONF_DIR/infinity_conf.toml" > "$LOG_DIR/infinity_startup.log" 2>&1 &
    fi

    # Infinity Embedding Server (TEI replacement)
    # Uses infinity-emb to serve compatible API on port 6380
    if ! pgrep -f "infinity_emb" > /dev/null; then
        log "Starting Infinity Embedding Server..."
        # Use TEI_MODEL from env, default to BAAI/bge-m3 if not set or invalid
        # RAGFlow .env default is Qwen/Qwen3-Embedding-0.6B
        MODEL_ID="${TEI_MODEL:-Qwen/Qwen3-Embedding-0.6B}"

        # Start server
        nohup infinity_emb v2 --port 6380 --model-id "$MODEL_ID" > "$LOG_DIR/infinity_emb.log" 2>&1 &
    fi

    # Nginx
    service nginx restart

    # RAGFlow
    log "Starting RAGFlow Server..."
    nohup python3 api/ragflow_server.py > "$LOG_DIR/ragflow_server.log" 2>&1 &

    log "Starting Task Executor..."
    HOST_ID=$(hostname)
    nohup python3 rag/svr/task_executor.py "${HOST_ID}_0" > "$LOG_DIR/task_executor.log" 2>&1 &

    log "Services started. Logs available in $LOG_DIR"
}

# Main Execution
if [ ! -f "$WORKSPACE_DIR/configured" ]; then
    setup_directories
    install_dependencies
    setup_python
    build_frontend
    configure_services
    touch "$WORKSPACE_DIR/configured"
else
    log "Environment already configured. Starting services..."
    source "$VENV_DIR/bin/activate"
fi

start_services

# Keep alive and show logs
tail -f "$LOG_DIR/ragflow_server.log"
