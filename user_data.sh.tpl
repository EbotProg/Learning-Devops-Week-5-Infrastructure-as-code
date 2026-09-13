#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl unzip git

# Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
CODENAME=$(. /etc/os-release && echo $VERSION_CODENAME)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
usermod -aG docker ubuntu

# AWS CLI (not preinstalled on plain Ubuntu)
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# Pull the app repo (has docker-compose.yml)
# CHANGE THIS to your actual repo if different
sudo -u ubuntu git clone https://github.com/EbotProg/Learning-Devops-Week-3-Docker-Deep-Dive.git /home/ubuntu/app
cd /home/ubuntu/app

# ECR login — uses THIS INSTANCE'S attached IAM role, no keys involved at all
aws ecr get-login-password --region eu-north-1 | docker login --username AWS --password-stdin ${account_id}.dkr.ecr.eu-north-1.amazonaws.com

# TEMPORARY — real secrets hardcoded here on purpose, for now.
# Week 6's entire job is replacing this block with a fetch from
# Secrets Manager / Parameter Store instead. Don't "fix" this yet.
cat > .env <<ENVEOF
ECR_REGISTRY=${account_id}.dkr.ecr.eu-north-1.amazonaws.com
IMAGE_TAG=latest
MONGO_ROOT_PASSWORD=ChangeThisBeforeWeek6
PARSE_MASTER_KEY=ChangeThisBeforeWeek6
PARSE_APP_ID=myAppId
DASHBOARD_USER=admin
DASHBOARD_PASSWORD=ChangeThisBeforeWeek6
ENVEOF
chown ubuntu:ubuntu .env
chmod 600 .env

docker compose up -d
