# 使用Alpine作为基础镜像
FROM python:3.11.4-slim-bookworm
# 更换Alpine镜像源
# RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
#     && apk add --no-cache tzdata

# ARG GITHUB_PAT
# ARG GITHUB_USERNAME
# ARG GITHUB_REPO
# ARG BRANCH="main"  # 默认分支为 main






# 设置环境变量
ENV LANG="C.UTF-8" \
    TZ="Asia/Shanghai" 

# 将 ARG 转换为 ENV
ENV GITHUB_PAT=
ENV GITHUB_USERNAME=
ENV GITHUB_REPO=
ENV BRANCH=mian
ENV PROXY_HOST=
ENV RUN_COMMAND="python3 main.py"
ENV ENTRYPOINT_URL="https://gitee.com/dxll/entrypoint/raw/main/entrypoint.sh"


# 设置工作目录
WORKDIR /app

# 打印构建参数
RUN echo "GITHUB_PAT: ${GITHUB_PAT}"
RUN echo "GITHUB_USERNAME: ${GITHUB_USERNAME}"
RUN echo "GITHUB_REPO: ${GITHUB_REPO}"

# 安装依赖包和Python 3.11
RUN apt-get update -y \
    && apt-get upgrade -y \
    && apt-get -y  install \
    curl  \
    wget \
    busybox \
    git\
    && pip install --upgrade pip



VOLUME [ "/config" ]


# 复制本地 entrypoint.sh 作为默认版本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 创建启动检查脚本
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# 检查是否设置了 ENTRYPOINT_URL\n\
if [ -n "${ENTRYPOINT_URL:-}" ] && [ "${ENTRYPOINT_URL}" != "" ]; then\n\
    echo "检查 entrypoint.sh 更新: ${ENTRYPOINT_URL}"\n\
    # 尝试下载新版本\n\
    if curl -fsSL "${ENTRYPOINT_URL}" -o /entrypoint.sh.new 2>/dev/null || wget -q -O /entrypoint.sh.new "${ENTRYPOINT_URL}" 2>/dev/null; then\n\
        echo "✓ 成功下载最新版本 entrypoint.sh"\n\
        chmod +x /entrypoint.sh.new\n\
        mv /entrypoint.sh.new /entrypoint.sh\n\
    else\n\
        echo "✗ 下载失败，使用现有版本"\n\
        rm -f /entrypoint.sh.new\n\
    fi\n\
else\n\
    echo "未设置 ENTRYPOINT_URL，使用现有 entrypoint.sh"\n\
fi\n\
\n\
# 执行 entrypoint.sh\n\
exec /entrypoint.sh "$@"\n\
' > /startup.sh && chmod +x /startup.sh





EXPOSE 4567/tcp



ENTRYPOINT ["/startup.sh"]


