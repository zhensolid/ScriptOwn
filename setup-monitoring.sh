#!/bin/bash

# 清屏
clear

# 检查并安装 tree 命令
if ! command -v tree >/dev/null 2>&1; then
    echo "正在安装 tree 命令..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y tree
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y tree
    else
        echo "无法安装 tree 命令，将使用 ls -R 替代"
    fi
fi

# 检查端口是否被占用
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null ; then
        return 1
    fi
    return 0
}

# 检查监控相关容器是否在运行
check_running_containers() {
    local container_patterns=("node_exporter" "prometheus" "grafana")
    local running_containers=()
    
    for pattern in "${container_patterns[@]}"; do
        # 使用模糊匹配查找包含关键字的容器
        local found_containers=$(docker ps --format '{{.Names}}' | grep -i "${pattern}")
        if [ ! -z "$found_containers" ]; then
            while IFS= read -r container; do
                running_containers+=("$container")
            done <<< "$found_containers"
        fi
    done
    
    if [ ${#running_containers[@]} -gt 0 ]; then
        echo "发现以下可能相关的监控容器正在运行："
        printf '%s\n' "${running_containers[@]}"
        echo "------------------------"
        echo "请选择操作："
        echo "1. 停止这些容器并继续部署"
        echo "2. 退出脚本"
        read -p "请输入选项 (1/2): " choice
        
        case $choice in
            1)
                echo "正在停止容器..."
                for container in "${running_containers[@]}"; do
                    echo "停止并删除容器: $container"
                    docker stop "$container" && docker rm "$container"
                done
                echo "所有容器已停止并删除"
                ;;
            2)
                echo "退出脚本"
                exit 0
                ;;
            *)
                echo "无效选项，退出脚本"
                exit 1
                ;;
        esac
    fi
}

# 检查并清理已存在的项目
check_existing_project() {
    local project_name=$1
    if [ -d "$project_name" ]; then
        echo "警告: 目录 $project_name 已存在！"
        echo "请选择操作："
        echo "1. 删除现有项目并重新创建"
        echo "2. 退出脚本"
        read -p "请输入选项 (1/2): " choice
        
        case $choice in
            1)
                echo "正在删除现有项目..."
                # 停止并删除容器
                if [ -f "$project_name/docker-compose.yml" ]; then
                    cd $project_name
                    docker-compose down
                    cd ..
                fi
                rm -rf $project_name
                echo "项目已删除"
                return 0
                ;;
            2)
                echo "退出脚本"
                exit 0
                ;;
            *)
                echo "无效选项，退出脚本"
                exit 1
                ;;
        esac
    fi
    return 0
}

echo "=== 监控系统部署脚本 ==="
echo "------------------------"

# 首先检查是否有相关容器在运行
check_running_containers

# 提示输入项目名称
echo "请输入项目名称 (默认: NPG):"
read PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-NPG}

# 检查已存在的项目
check_existing_project $PROJECT_NAME

# 获取 Grafana 端口
echo "请输入 Grafana 访问端口 (默认: 3000):"
read PORT
PORT=${PORT:-3000}

# 验证端口
while true; do
    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
        echo "错误: 请输入有效的数字端口"
        read PORT
        continue
    fi
    
    if ! check_port $PORT; then
        echo "错误: 端口 $PORT 已被占用，请选择其他端口"
        read PORT
        continue
    fi
    
    break
done

GRAFANA_PORT=$PORT

# 提示输入 Grafana 密码
echo "请输入 Grafana 管理员密码 (默认: admin123):"
read GRAFANA_PASSWORD
GRAFANA_PASSWORD=${GRAFANA_PASSWORD:-admin123}

echo "------------------------"
echo "确认信息："
echo "项目名称: $PROJECT_NAME"
echo "Grafana端口: $GRAFANA_PORT"
echo "Grafana密码: $GRAFANA_PASSWORD"
echo "------------------------"
echo "是否继续? (y/n)"
read CONFIRM

if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
    echo "取消部署"
    exit 1
fi

mkdir -p $PROJECT_NAME
cd $PROJECT_NAME

# 创建必要的目录
mkdir -p data/prometheus data/grafana prometheus

# 创建 prometheus.yml
cat > prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['node_exporter:9100']
EOF

# 创建 docker-compose.yml（使用变量替换密码和端口）
cat > docker-compose.yml << EOF
version: '3.8'

services:
  node_exporter:
    image: prom/node-exporter:latest
    container_name: node_exporter
    restart: unless-stopped
    networks:
      - monitoring
    command:
      - '--path.rootfs=/host'
    pid: host
    volumes:
      - '/:/host:ro,rslave'

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    networks:
      - monitoring
    volumes:
      - ./prometheus:/etc/prometheus
      - ./data/prometheus:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    networks:
      - monitoring
    ports:
      - "${GRAFANA_PORT}:3000"
    volumes:
      - ./data/grafana:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}

networks:
  monitoring:
    driver: bridge
EOF

# 设置目录权限
chmod 777 data/prometheus data/grafana

echo "
=== 部署完成 ==="
echo "项目创建在: $(pwd)/${PROJECT_NAME}"
echo "目录结构如下："
cd $PROJECT_NAME
if command -v tree >/dev/null 2>&1; then
    tree .
else
    echo "提示：未安装 tree 命令，无法显示目录结构"
fi
cd ..

echo "
配置信息：
- 项目名称: ${PROJECT_NAME}
- Grafana 访问地址: http://localhost:${GRAFANA_PORT}
- Grafana 管理员用户名: admin
- Grafana 管理员密码: ${GRAFANA_PASSWORD}

后续步骤：
1. cd ${PROJECT_NAME}
2. 运行 docker-compose up -d 启动服务
3. 访问 http://localhost:${GRAFANA_PORT} 登录 Grafana

是否现在启动服务? (y/n)"
read START

if [[ $START == "y" || $START == "Y" ]]; then
    echo "正在启动服务..."
    cd $PROJECT_NAME
    docker-compose up -d
    echo "服务已启动！"
    echo "可以通过 http://localhost:${GRAFANA_PORT} 访问 Grafana"
    echo "Prometheus数据地址为http://prometheus:9090"
    cd ..
fi 