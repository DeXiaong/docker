#!/bin/bash

set -euo pipefail

# 设置环境变量、工作目录等（如果需要）
# 例如：
# export PYTHONPATH=/app


# 验证环境变量
# echo "GITHUB_PAT: ${GITHUB_PAT}"
# echo "GITHUB_USERNAME: ${GITHUB_USERNAME}"
# echo "GITHUB_REPO: ${GITHUB_REPO}"

# 判断使用 Gitee 还是 GitHub
if [ -n "${GITEE_TOKEN:-}" ]; then
    # 使用 Gitee 配置
    echo "检测到 Gitee 配置,使用 Gitee 仓库"
    GIT_REPO="https://${GITEE_USERNAME}:${GITEE_TOKEN}@gitee.com/${GITEE_USERNAME}/${GITHUB_REPO}.git"
else
    # 使用 GitHub 配置
    echo "使用 GitHub 仓库"
    GIT_REPO="https://${GITHUB_PAT}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
fi

TARGET_DIR="/app"
BRANCH="${BRANCH:-main}"

# 小函数：判断目录是否为空
is_empty_dir() { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }

# 配置代理（如果设置了 PROXY_HOST 且不为空）
if [ -n "${PROXY_HOST:-}" ] && [ "${PROXY_HOST}" != "" ]; then
    echo "配置代理: $PROXY_HOST"
    export http_proxy="${PROXY_HOST}"
    export https_proxy="${PROXY_HOST}"
    export HTTP_PROXY="${PROXY_HOST}"
    export HTTPS_PROXY="${PROXY_HOST}"
    export ALL_PROXY="${PROXY_HOST}"
    export all_proxy="${PROXY_HOST}"
    
    # Git 不支持 SOCKS5 代理,只为 HTTP/HTTPS 代理配置 Git
    if [[ "${PROXY_HOST}" == http://* ]] || [[ "${PROXY_HOST}" == https://* ]]; then
        git config --global http.proxy "${PROXY_HOST}"
        git config --global https.proxy "${PROXY_HOST}"
        echo "Git 已配置代理"
    else
        echo "检测到 SOCKS5 代理,Git 将直连(不支持 SOCKS5)"
    fi
else
    echo "未设置代理，直连 Git 仓库"
fi

# 配置 Git 认证
echo "从储存库克隆..."
git config --global credential.helper store

# 根据平台配置认证信息
if [ -n "${GITEE_TOKEN:-}" ]; then
    echo "https://${GITEE_USERNAME}:${GITEE_TOKEN}@gitee.com" > ~/.git-credentials
else
    echo "https://${GITHUB_PAT}:x-oauth-basic@github.com" > ~/.git-credentials
fi


# 如果是 Debian/Ubuntu 基础镜像
# 安装系统依赖（用于编译 asyncpg 和 psycopg2）
echo "安装系统依赖..."
if command -v apt-get &> /dev/null; then
    # Debian/Ubuntu (apt-get 不支持 SOCKS5,临时取消代理)
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
        apt-get update && \
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
        apt-get install -y libpq-dev gcc python3-dev && \
    rm -rf /var/lib/apt/lists/*
elif command -v apk &> /dev/null; then
    # Alpine
    apk add --no-cache postgresql-dev gcc python3-dev musl-dev
fi


ACTION="none"

# 检查 /app 目录是否已存在 Git 仓库或为空
if [ -d "$TARGET_DIR/.git" ]; then
    # 如果存在 Git 仓库，进入目录并更新代码
    echo "更新现有仓库在 $TARGET_DIR..."
    git -C "$TARGET_DIR" fetch origin "$BRANCH"
    git -C "$TARGET_DIR" reset --hard "origin/$BRANCH"
    ACTION="pull"
elif is_empty_dir "$TARGET_DIR"; then
    # 如果目录为空，克隆新的仓库
    echo "从储存库克隆到 $TARGET_DIR..."
    git clone -b "$BRANCH" "$GIT_REPO" "$TARGET_DIR"
    ACTION="clone"
else
    # 目录非空且不是 Git 仓库（多见于挂载了宿主机目录）
    echo "[warn] $TARGET_DIR 非空且不是 Git 仓库，跳过 clone，使用现有文件。"
    ACTION="skip"
fi

# 根据执行结果给出提示
if [ "$ACTION" = "clone" ] || [ "$ACTION" = "pull" ]; then
    echo "从储存库$([ "$ACTION" = "clone" ] && echo 克隆 || echo 更新)成功."
else
    # 跳过 clone 的场景：不视为失败，但提示如何切换到‘仓库模式’
    echo "已跳过从储存库克隆/更新（目录非空且非 Git 仓库）。若需使用 Git，请清空 $TARGET_DIR 或更改 TARGET_DIR 至空目录（例如 /src）。"
fi

# 进入目标目录
cd "$TARGET_DIR"

# 更新依赖
pip install --upgrade -i https://mirrors.aliyun.com/pypi/simple/ pip
# 查找所有 requirements.txt 文件，并对每个文件执行 pip install
find . -name "requirements.txt" | while read file; do
    echo "找到 requirements.txt in: $(dirname "$file")"
    echo "安装依赖 $file..."
    pip install -r "$file"
done



# 检查pip安装是否成功
if [ $? -eq 0 ]; then
    echo "所有依赖已更新完毕."
else
    echo "更新依赖失败,退出"
    exit 1
fi

# 启动你的应用
# 使用 RUN_COMMAND 环境变量或默认命令
if [ -n "${RUN_COMMAND:-}" ] && [ "${RUN_COMMAND}" != "" ]; then
    echo "使用自定义启动命令: $RUN_COMMAND"
    exec $RUN_COMMAND
else
    echo "使用默认启动命令: python3 main.py"
    exec python3 main.py
fi