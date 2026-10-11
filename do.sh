#!/bin/bash
#
# Docker 安装 / 卸载脚本（Debian、Ubuntu 系，面向国内 VPS）
#
#   ./do.sh        安装 Docker（默认）
#   ./do.sh -i     安装 Docker
#   ./do.sh -c     只做安装前环境检测，不做任何改动
#   ./do.sh -u     卸载 Docker
#   ./do.sh -h     帮助
#
# 环境变量：
#   DOCKER_MIRROR       Docker CE 仓库镜像，默认 https://mirrors.aliyun.com/docker-ce
#   REGISTRY_MIRROR     镜像加速器，默认 https://docker.m.daocloud.io
#
# 安装前会检测：发行版/代号、CPU 架构、内核版本、虚拟化类型（OpenVZ/LXC/容器）、
# mount 与 cgroup 权限、overlayfs、iptables，判定这台机器能不能跑 Docker；
# 能跑但有欠缺的（无 overlayfs、无 NAT 权限）会自动降级到 vfs / 关闭 bridge。

set -uo pipefail

DOCKER_MIRROR="${DOCKER_MIRROR:-https://mirrors.aliyun.com/docker-ce}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-https://docker.m.daocloud.io}"
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-compose-plugin)

# 检测结果（由 detect_distro / check_system 填写）
REPO_FAMILY=""
CODENAME=""
ARCH=""
VIRT="未知"
HAS_SYSTEMD=no
NEED_NO_IPTABLES=no
NEED_VFS=no

CAPEFF="$(awk '/^CapEff/ {print $2}' /proc/self/status 2>/dev/null | head -n 1)"

ok()   { echo "[ OK ] $*"; }
bad()  { echo "[FAIL] $*"; }
warn() { echo "[WARN] $*"; }
info() { echo "[info] $*"; }
hr()   { echo "----------------------------------------------------------"; }

# 判断 CapEff 里的第 bit 位是否为 1（不用 capsh，避免 bash 对 64 位十六进制溢出）
cap_has() {
    local bit="$1" idx digit need hex
    [ -n "$CAPEFF" ] || return 2
    hex=$(printf '%016s' "$CAPEFF" | tr ' ' '0' | tr 'A-F' 'a-f')
    idx=$(( bit / 4 ))
    need=$(( 1 << (bit % 4) ))
    digit=$(printf '%s' "$hex" | cut -c $(( 16 - idx )))
    [ -n "$digit" ] || return 2
    [ $(( 0x$digit & need )) -ne 0 ]
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用root权限运行此脚本" >&2
        exit 1
    fi
}

# 识别发行版家族（ubuntu/debian）、代号、CPU 架构
detect_distro() {
    if [ ! -r /etc/os-release ]; then
        bad "读不到 /etc/os-release，无法识别发行版（本脚本只支持 Linux 的 Debian/Ubuntu 系）"
        return 1
    fi

    . /etc/os-release

    # Docker 官方仓库只有 ubuntu 和 debian 两套，派生发行版归到对应上游
    case "${ID:-}" in
        ubuntu|linuxmint|pop|elementary|neon|zorin) REPO_FAMILY=ubuntu ;;
        debian|raspbian|armbian|devuan)            REPO_FAMILY=debian ;;
        *)
            bad "不支持的发行版: ${ID:-未知}（本脚本只处理 Debian/Ubuntu 系）"
            return 1
            ;;
    esac

    # Ubuntu 系优先取 UBUNTU_CODENAME（Mint 这类派生的 VERSION_CODENAME 不是 Ubuntu 代号）
    if [ "$REPO_FAMILY" = ubuntu ]; then
        CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    else
        CODENAME="${VERSION_CODENAME:-}"
    fi
    if [ -z "$CODENAME" ] && command -v lsb_release >/dev/null 2>&1; then
        CODENAME="$(lsb_release -cs)"
    fi
    if [ -z "$CODENAME" ]; then
        bad "无法确定发行版代号（codename）"
        return 1
    fi

    ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$ARCH" in
        x86_64)  ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
    esac

    info "系统: ${PRETTY_NAME:-$ID}   架构: $ARCH   内核: $(uname -r 2>/dev/null)"
    return 0
}

# 虚拟化类型：老 OpenVZ / LXC / 容器里跑 dockerd 是最常见的"装不上"原因
detect_virt() {
    local v=""

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v="$(systemd-detect-virt 2>/dev/null || true)"
        if [ -z "$v" ] || [ "$v" = none ] || [ "$v" = unknown ]; then
            v=""
        fi
    fi

    if [ -z "$v" ]; then
        # 没有 systemd-detect-virt 或识别不出时，看内核痕迹
        if [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
            v="openvz6（旧版 OpenVZ）"
        elif [ -f /proc/user_beancounters ]; then
            v="openvz/virtuozzo"
        elif grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
            v="lxc"
        elif [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
            v="docker容器内"
        else
            v="物理机或未识别"
        fi
    fi

    VIRT="$v"
    info "虚拟化类型: $VIRT"
}

check_kernel() {
    local kver major minor rest
    kver="$(uname -r 2>/dev/null)"
    major="${kver%%.*}"
    rest="${kver#*.}"
    minor="${rest%%.*}"
    major="${major//[!0-9]/}"
    minor="${minor//[!0-9]/}"

    if [ -n "$major" ] && { [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -lt 10 ]; }; }; then
        bad "内核 $kver 太老：Docker 要求 >= 3.10（2.6.32 的老 OpenVZ 机器属于此类）"
        return 1
    fi
    ok "内核版本 $kver 满足要求（>= 3.10）"
    return 0
}

# 安装前环境检测：返回 0 表示可以装，1 表示这台机器跑不了 dockerd
check_system() {
    local failed=0 tmpd p

    echo "===== 安装前环境检测 ====="

    detect_distro || return 1
    detect_virt

    # 1) CPU 架构：镜像站实际提供 amd64/arm64/armhf/s390x
    case "$ARCH" in
        amd64|arm64|armhf|s390x)
            ok "CPU 架构 $ARCH 受支持"
            ;;
        i386|386|i686)
            bad "CPU 架构 $ARCH（32 位 x86）不受支持：Docker 没有 32 位版本，请换 64 位系统"
            return 1
            ;;
        ppc64le)
            bad "CPU 架构 $ARCH 不受支持：Docker CE 已停止发布 ppc64le 包"
            return 1
            ;;
        *)
            bad "CPU 架构 $ARCH 不受支持：仓库里没有对应的 docker-ce 包"
            return 1
            ;;
    esac

    # 2) 内核版本
    check_kernel || return 1

    # 3) 与发行版自带的 docker.io/containerd 冲突检查
    for p in docker.io containerd; do
        if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
            bad "系统已安装 $p，会和 docker-ce 抢同一个 /usr/bin/docker 而冲突"
            echo "      请先执行: apt-get remove -y docker.io containerd docker-compose  再重跑本脚本" >&2
            return 1
        fi
    done
    if command -v docker >/dev/null 2>&1; then
        info "已存在 docker 命令（$(docker --version 2>/dev/null || echo 版本未知)），本次执行安装或升级"
    fi

    # 4) mount 权限 + overlayfs：DinD / OpenVZ 最容易卡在这里
    tmpd="$(mktemp -d 2>/dev/null || true)"
    if [ -n "$tmpd" ]; then
        mkdir -p "$tmpd/mnt" "$tmpd/ovl/lower" "$tmpd/ovl/upper" "$tmpd/ovl/work" "$tmpd/ovl/merged"
        if mount -t tmpfs tmpfs "$tmpd/mnt" 2>/dev/null; then
            ok "mount 权限正常（tmpfs 实测通过）"
            umount "$tmpd/mnt" 2>/dev/null

            if mount -t overlay overlay \
                -o "lowerdir=$tmpd/ovl/lower,upperdir=$tmpd/ovl/upper,workdir=$tmpd/ovl/work" \
                "$tmpd/ovl/merged" 2>/dev/null; then
                ok "overlayfs 可用（使用默认 overlay2 存储驱动）"
                umount "$tmpd/ovl/merged" 2>/dev/null
            else
                warn "overlayfs 不可用，将自动降级为 vfs 存储驱动（能用，但慢且费磁盘）"
                NEED_VFS=yes
            fi
        else
            bad "没有 mount 权限：dockerd 无法准备联合文件系统，起不来"
            failed=1
        fi
        rm -rf "$tmpd" 2>/dev/null
    else
        warn "无法创建临时目录，跳过 mount 检测"
    fi

    # 5) cgroup 可写性：只读的 cgroup 会让 docker run 全部失败
    if awk '$3 == "/sys/fs/cgroup" {found=1} END {exit !found}' /proc/mounts 2>/dev/null; then
        if mkdir "/sys/fs/cgroup/docker-check.$$" 2>/dev/null; then
            rmdir "/sys/fs/cgroup/docker-check.$$" 2>/dev/null
            ok "cgroup 可写（dockerd 能为容器建 cgroup）"
        else
            bad "cgroup 不可写（/sys/fs/cgroup 只读）：容器创建会失败"
            failed=1
        fi
    else
        bad "cgroup 未挂载：dockerd 无法管理容器资源"
        failed=1
    fi

    # 6) iptables：缺 CAP_NET_ADMIN 时可降级（容器只能用 host 网络）
    if ! command -v iptables >/dev/null 2>&1; then
        warn "当前没有 iptables 命令（docker-ce 会把它作为依赖装进来）"
    elif iptables -t nat -L -n >/dev/null 2>&1; then
        ok "iptables nat 可用（bridge 网络正常）"
    else
        warn "iptables 操作被拒（多为容器内缺 CAP_NET_ADMIN），将自动关闭 iptables/bridge"
        NEED_NO_IPTABLES=yes
    fi
    if cap_has 21; then
        ok "CAP_SYS_ADMIN 具备"
    else
        info "当前进程无 CAP_SYS_ADMIN（物理机/KVM 上正常，容器里是问题）"
    fi

    # 7) init 系统决定后面怎么启动 docker
    if [ -d /run/systemd/system ] && [ "$(ps -p 1 -o comm= 2>/dev/null | head -n 1)" = systemd ]; then
        HAS_SYSTEMD=yes
        ok "systemd 可用（用 systemctl 管理 docker）"
    else
        warn "没有 systemd：安装后用 dockerd 直接启动（机器重启后需重新拉起）"
    fi

    hr
    if [ "$failed" -ne 0 ]; then
        echo "结论: 这台机器不支持运行 Docker，已中止，未做任何改动。"
        case "$VIRT" in
            openvz*)
                echo "      虚拟化类型是 $VIRT：这类容器没有 mount / cgroup 权限，dockerd 无法启动。"
                echo "      建议换 KVM 架构的机器，或让服务商确认是否开启 Docker 支持（需 Virtuozzo 7 及以上）。"
                ;;
            lxc)
                echo "      虚拟化类型是 LXC：需要服务商在宿主侧开放 privileged、cgroup 挂载和 iptables 权限，否则跑不起来。"
                ;;
            docker容器内)
                echo "      当前在 Docker 容器内：需以 --privileged --cgroupns=host 启动容器，"
                echo "      或干脆不自己装，把宿主机的 /var/run/docker.sock 挂进来复用宿主 Docker。"
                ;;
            *)
                echo "      缺少上面 [FAIL] 的前置条件，dockerd 无法启动。"
                ;;
        esac
        return 1
    fi
    echo "结论: 环境支持安装 Docker。"
    return 0
}

# 生成 /etc/docker/daemon.json（镜像加速 + 按检测结果降级）
configure_daemon() {
    echo "配置Docker镜像加速器..."
    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
        info "已备份原配置到 /etc/docker/daemon.json.bak"
    fi

    {
        printf '{\n'
        printf '  "registry-mirrors": ["%s"]' "$REGISTRY_MIRROR"
        if [ "$NEED_NO_IPTABLES" = yes ]; then
            printf ',\n  "iptables": false,\n  "ip-forward": false,\n  "bridge": "none"'
        fi
        if [ "$NEED_VFS" = yes ]; then
            printf ',\n  "storage-driver": "vfs"'
        fi
        printf '\n}\n'
    } > /etc/docker/daemon.json

    # 有可用的 python3 就顺手验一下 JSON；验不了不算错误，dockerd 启动时还会再校验一次
    if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
        python3 -c 'import json; json.load(open("/etc/docker/daemon.json"))' >/dev/null 2>&1 \
            || warn "daemon.json 未通过 JSON 校验，请人工核对 /etc/docker/daemon.json"
    fi
    return 0
}

# 没有 systemd 的环境（LXC、容器）直接拉起 dockerd
start_dockerd_directly() {
    if command -v pgrep >/dev/null 2>&1 && pgrep -x dockerd >/dev/null 2>&1; then
        pkill -x dockerd || true
        sleep 2
    fi

    echo "当前环境没有 systemd，直接启动 dockerd（日志: /var/log/dockerd.log）"
    nohup dockerd >/var/log/dockerd.log 2>&1 &

    local i
    for i in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "dockerd 30 秒内未就绪，日志尾部：" >&2
    tail -n 30 /var/log/dockerd.log >&2 || true
    return 1
}

start_docker() {
    if [ "$HAS_SYSTEMD" = yes ]; then
        systemctl daemon-reload
        systemctl enable docker
        systemctl restart docker  # 重启使 daemon.json 生效
    else
        start_dockerd_directly
    fi
}

# 安装Docker
install_docker() {
    check_system || exit 1

    echo "===== 开始安装Docker ====="

    # 上次失败可能留下指向错误仓库的 docker.list，否则下面第一次 apt update 又会失败
    rm -f /etc/apt/sources.list.d/docker.list

    echo "更新系统并安装依赖包..."
    apt-get update || warn "apt update 未完全成功，继续尝试"
    if ! apt-get -o Acquire::Retries=3 install -y ca-certificates curl gnupg lsb-release; then
        bad "依赖包安装失败，请检查上面的 apt 输出"
        exit 1
    fi

    # 仓库可达性：老系统/新系统的代号在镜像里可能根本没有
    local release_url="$DOCKER_MIRROR/linux/$REPO_FAMILY/dists/$CODENAME/Release"
    if ! curl -fsI "$release_url" >/dev/null; then
        bad "镜像站上没有该仓库: $release_url"
        echo "      说明 ${PRETTY_NAME:-$CODENAME} 这个代号在该镜像里没有 Docker 仓库。" >&2
        echo "      可换官方源重试: DOCKER_MIRROR=https://download.docker.com bash $0" >&2
        exit 1
    fi
    ok "仓库可用: $release_url"

    echo "准备Docker密钥..."
    mkdir -p /etc/apt/keyrings
    if ! curl -fsSL "$DOCKER_MIRROR/linux/$REPO_FAMILY/gpg" \
        | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg; then
        bad "下载 Docker GPG 密钥失败"
        exit 1
    fi
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "配置Docker软件源..."
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] $DOCKER_MIRROR/linux/$REPO_FAMILY $CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list

    echo "安装Docker引擎..."
    apt-get update || warn "apt update 未完全成功，继续尝试"
    if ! apt-get -o Acquire::Retries=3 install -y "${DOCKER_PACKAGES[@]}"; then
        warn "首次安装失败，重试一次（国内网络偶发超时）"
        apt-get update || true
        if ! apt-get -o Acquire::Retries=3 install -y "${DOCKER_PACKAGES[@]}"; then
            bad "Docker 组件安装失败，请检查上面的 apt 输出"
            exit 1
        fi
    fi

    configure_daemon || exit 1

    echo "启动Docker服务..."
    if ! start_docker; then
        bad "===== Docker 已安装，但守护进程启动失败 ====="
        if [ "$HAS_SYSTEMD" != yes ]; then
            echo "      当前没有 systemd，dockerd 是直接拉起的，日志见 /var/log/dockerd.log" >&2
        else
            echo "      可执行 systemctl status docker 和 journalctl -u docker -n 50 查看原因" >&2
        fi
        exit 1
    fi

    # 验证安装结果：CLI 和守护进程都要通才算成功
    if docker --version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "===== Docker安装配置完成！ ====="
        docker --version
        docker info --format '存储驱动: {{.Driver}}   Docker 根目录: {{.DockerRootDir}}'
        echo "镜像加速器: $REGISTRY_MIRROR"
        [ "$NEED_VFS" = yes ] && warn "已按环境降级：存储驱动 vfs（后续若宿主机支持 overlay，可删掉 daemon.json 里的 storage-driver 再重启）"
        [ "$NEED_NO_IPTABLES" = yes ] && warn "已按环境降级：关闭了 iptables/bridge，docker run 需加 --network host 才能通网"
        [ "$HAS_SYSTEMD" != yes ] && warn "没有 systemd：dockerd 是普通进程，机器重启后不会自动起来（可用 -i 重新拉起）"
        # 加速器可达性只是提示，不影响安装结果
        local code
        code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "https://${REGISTRY_MIRROR#*://}/v2/" 2>/dev/null || true)"
        case "$code" in
            200|301|302|307|401|403) ok "镜像加速器可达（HTTP $code）" ;;
            *) warn "镜像加速器暂时探测不到响应（HTTP ${code:-无}），拉镜像时若超时可用 REGISTRY_MIRROR=... 换一个" ;;
        esac
    else
        bad "===== Docker安装失败，请检查错误信息。 ====="
        exit 1
    fi
}

# 卸载Docker
uninstall_docker() {
    echo "===== 开始卸载Docker ====="

    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker未安装，无需卸载"
        exit 0
    fi

    echo "停止Docker服务..."
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop docker docker.socket 2>/dev/null || true
        systemctl disable docker docker.socket 2>/dev/null || true
    elif command -v pkill >/dev/null 2>&1 && pgrep -x dockerd >/dev/null 2>&1; then
        pkill -x dockerd || true
        sleep 2
    fi

    echo "卸载Docker组件..."
    apt-get purge -y "${DOCKER_PACKAGES[@]}" || true

    echo "清理Docker配置和数据目录..."
    rm -rf /etc/docker
    rm -f /etc/apt/keyrings/docker.gpg
    rm -f /etc/apt/sources.list.d/docker.list
    rm -rf /var/lib/docker
    rm -rf /var/lib/containerd

    echo "清理系统残留包..."
    apt-get autoremove -y || true
    apt-get autoclean || true

    if ! command -v docker >/dev/null 2>&1; then
        echo "===== Docker卸载完成！ ====="
        echo "注意：Docker容器和镜像数据已删除"
    else
        echo "===== Docker卸载失败，请检查错误信息。 =====" >&2
        exit 1
    fi
}

show_help() {
    echo "Docker安装与卸载管理脚本（Debian/Ubuntu，国内 VPS）"
    echo
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -i   安装Docker（默认选项，会先做环境检测）"
    echo "  -c   只做安装前环境检测，不做任何改动"
    echo "  -u   卸载Docker"
    echo "  -h   显示帮助信息"
    echo
    echo "环境变量:"
    echo "  DOCKER_MIRROR=...      Docker 仓库镜像（默认阿里云）"
    echo "  REGISTRY_MIRROR=...    镜像加速器（默认 daocloud）"
}

check_root

case "${1:-}" in
    -i|-install)
        install_docker
        ;;
    -c|--check)
        check_system
        ;;
    -u|--uninstall)
        uninstall_docker
        ;;
    -h|--help)
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
