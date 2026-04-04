#!/bin/bash
# Ubuntu Docker 安装脚本

# 移除掉旧的版本
sudo apt-get remove -y docker \
                  docker-engine \
                  docker.io \
                  containerd \
                  runc

# 删除所有旧的数据
sudo rm -rf /var/lib/docker
sudo rm -rf /var/lib/containerd

# 更新软件包索引
sudo apt-get update

# 安装依赖包
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# 添加 Docker 官方 GPG 密钥
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# 设置 Docker 仓库（使用阿里云镜像）
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 更新软件包索引
sudo apt-get update

# 安装最新稳定版本的 Docker
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 配置镜像加速器
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.ccs.tencentyun.com"
  ]
}
EOF

# 启动 Docker 引擎并设置开机启动
sudo systemctl start docker
sudo systemctl enable docker

# 配置当前用户对 docker 的执行权限
sudo groupadd docker
sudo usermod -aG docker ${USER}

# 重启 Docker 服务
sudo systemctl restart docker

# 验证安装
echo "========================================="
echo "Docker 安装完成！"
echo "========================================="
docker --version
echo ""
echo "请注意：需要重新登录或运行以下命令使用户组权限生效："
echo "  newgrp docker"
echo ""
echo "或者直接重启系统"
