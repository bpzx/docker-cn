#!/bin/bash

# 确保脚本以root权限运行
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用root权限运行此脚本" >&2
        exit 1
    fi
}

# 安装Docker
install_docker() {
    echo "===== 开始安装Docker ====="
    
    # 更新系统并安装必要的依赖包
    echo "更新系统并安装依赖包..."
    apt update && apt install -y ca-certificates curl gnupg lsb-release

    # 创建Docker密钥存储目录
    echo "准备Docker密钥..."
    mkdir -p /etc/apt/keyrings

    # 下载并安装Docker GPG密钥
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    # 添加Docker软件源（使用阿里云镜像）
    echo "配置Docker软件源..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # 安装Docker引擎
    echo "安装Docker引擎..."
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # 配置Docker镜像加速器
    echo "配置Docker镜像加速器..."
    mkdir -p /etc/docker
    tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io"
  ]
}
EOF

    # 重启Docker服务使配置生效
    echo "重启Docker服务..."
    systemctl daemon-reload
    systemctl restart docker
    systemctl enable docker  # 设置开机自启

    # 验证安装结果
    if docker --version >/dev/null 2>&1; then
        echo "===== Docker安装配置完成！ ====="
        docker --version
    else
        echo "===== Docker安装失败，请检查错误信息。 =====" >&2
        exit 1
    fi
}

# 卸载Docker
uninstall_docker() {
    echo "===== 开始卸载Docker ====="
    
    # 检查Docker是否安装
    if ! command -v docker &> /dev/null; then
        echo "Docker未安装，无需卸载"
        exit 0
    fi

    # 停止Docker服务
    echo "停止Docker服务..."
    systemctl stop docker
    systemctl disable docker

    # 卸载Docker包
    echo "卸载Docker组件..."
    apt purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # 删除Docker相关目录
    echo "清理Docker配置和数据目录..."
    rm -rf /etc/docker
    rm -rf /etc/apt/keyrings/docker.gpg
    rm -rf /etc/apt/sources.list.d/docker.list
    rm -rf /var/lib/docker
    rm -rf /var/lib/containerd

    # 清理无用依赖
    echo "清理系统残留包..."
    apt autoremove -y
    apt autoclean

    # 验证卸载结果
    if ! command -v docker &> /dev/null; then
        echo "===== Docker卸载完成！ ====="
        echo "注意：Docker容器和镜像数据已删除"
    else
        echo "===== Docker卸载失败，请检查错误信息。 =====" >&2
        exit 1
    fi
}

# 显示帮助信息
show_help() {
    echo "Docker安装与卸载管理脚本"
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -i   安装Docker（默认选项）"
    echo "  -u 卸载Docker"
    echo "  -h      显示帮助信息"
}

# 主程序
check_root

case "$1" in
    -install)
        install_docker
        ;;
    -u)
        uninstall_docker
        ;;
    -h)
        show_help
        ;;
    "")
        install_docker
        ;;
    *)
        echo "未知选项: $1" >&2
        show_help >&2
        exit 1
        ;;
esac
