#!/bin/bash
# remove old version
sudo yum remove docker \
                  docker-client \
                  docker-client-latest \
                  docker-common \
                  docker-latest \
                  docker-latest-logrotate \
                  docker-logrotate \
                  docker-selinux \
                  docker-engine-selinux \
                  docker-engine

# remove all docker data 
sudo rm -rf /var/lib/docker

#  preinstall utils 
sudo yum install -y yum-utils \
  device-mapper-persistent-data \
  lvm2

# add repository
sudo yum-config-manager \
    --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo

# make cache
sudo yum makecache fast

# install the latest stable version of docker
sudo yum install -y docker-ce

# start deamon and enable auto start when power on
#启动docker
sudo systemctl start docker
#设置开机启动
sudo systemctl enable docker

# add current user 
sudo groupadd docker
sudo gpasswd -a ${USER} docker
sudo systemctl restart docker
