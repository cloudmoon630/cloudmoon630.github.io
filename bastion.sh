#!/bin/bash

CLUSTER='skills-cluster'
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
# TOLERATION_KEY='management'
# TOLERATION_VALUE='addon'


case $(whoami) in
    root) SUDO="" ;;
    *) SUDO="sudo" ;;
esac


configure_al2023 () {
    $SUDO yum install -y docker mariadb105 postgresql15 libxcrypt-compat
    python3 -m ensurepip
}


configure_al2 () {
    amazon-linux-extras install -y docker mariadb10.5 postgresql14 python3.8 epel
    rm -f /usr/bin/python3 && ln -s /usr/bin/python3.8 /usr/bin/python3
}


install_tools () {
    # Git, jq, npm, amazon cloudwatch agent
    $SUDO yum install -y git jq amazon-cloudwatch-agent amazon-efs-utils

    cat << 'EOF' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d/config.json
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/app/app.log",
            "log_group_class": "STANDARD",
            "log_group_name": "/skills/app/output",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 90
          },
          {
            "file_path": "/var/log/app/error.log",
            "log_group_class": "STANDARD",
            "log_group_name": "/skills/app/error",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 90
          }
        ]
      }
    }
  },
  "metrics": {
    "aggregation_dimensions": [["InstanceId"]],
    "append_dimensions": {
      "AutoScalingGroupName": "${aws:AutoScalingGroupName}",
      "ImageId": "${aws:ImageId}",
      "InstanceId": "${aws:InstanceId}",
      "InstanceType": "${aws:InstanceType}"
    },
    "metrics_collected": {
      "disk": {
        "measurement": ["used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["*"]
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "statsd": {
        "metrics_aggregation_interval": 60,
        "metrics_collection_interval": 10,
        "service_address": ":8125"
      }
    }
  }
}
EOF

    # Docker
    $SUDO systemctl enable --now docker
    $SUDO usermod -aG docker ec2-user

    # AWS CLI v2
    curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "/tmp/awscliv2.zip"
    unzip /tmp/awscliv2.zip -d /tmp
    $SUDO mv /bin/aws /bin/awsv1
    $SUDO /tmp/aws/install
    $SUDO ln -s /usr/local/bin/aws /usr/bin/aws

    # npm & elb-log-analyzer
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    source ~/.bashrc
    nvm install 16
    npm install -g elb-log-analyzer
}


install_k8s_tools () {
    # Download kubectl
    case $(uname -m) in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
    esac

    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/$ARCH/kubectl"
    $SUDO install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    
    # Download eksctl
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_Linux_$ARCH.tar.gz" | tar xz -C /tmp
    $SUDO mv /tmp/eksctl /usr/local/bin

    # Download helm
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # Download k9s
    curl -sL https://github.com/derailed/k9s/releases/download/v0.32.5/k9s_Linux_$ARCH.tar.gz | tar xz -C /tmp
    $SUDO mv /tmp/k9s /usr/local/bin

    # Configure EKS variables on shell login
    cat << EOF | $SUDO tee /etc/profile.d/kubevar.sh > /dev/null
#!/bin/bash -eux

source <(kubectl completion bash)
source <(eksctl completion bash)

case \$(uname -m) in
    x86_64) export ARCH="amd64" ;;
    aarch64) export ARCH="arm64" ;;
esac

CLUSTER='$CLUSTER' && export CLUSTER
AWS_ACCOUNT_ID='$AWS_ACCOUNT_ID' && export AWS_ACCOUNT_ID
# TOLERATION_KEY='$TOLERATION_KEY' && export TOLERATION_KEY
# TOLERATION_VALUE='$TOLERATION_VALUE' && export TOLERATION_VALUE
# HELM_TOLERATION='--set tolerations[0].key='\$TOLERATION_KEY' --set tolerations[0].value='\$TOLERATION_VALUE' --set tolerations[0].effect=NoSchedule --set nodeSelector.'\$TOLERATION_KEY'='\$TOLERATION_VALUE && export HELM_TOLERATION
EOF
}


add_aws_region_warning () {
    cat << EOF | $SUDO tee /etc/profile.d/aws_region_warning.sh > /dev/null
#!/bin/bash

BRed='\033[1;31m'
NoColor='\033[0m'

if [ ! -f ~/.aws/config ] || ! grep -q region ~/.aws/config
then
    echo -e \${BRed}Configure AWS region first\${NoColor}
fi
EOF
}


add_commands () {
    cat << EOF | sudo tee /etc/profile.d/mycommands.sh > /dev/null
#!/bin/bash

myhelp () {
    cat << 1EOF
Commands list:
    image_push  IMAGE IMAGE:TAG
    logs        <recent|status|long|sync> PATH
    proxy       UPSTREAM_ENDPOINT
    daemonize   COMMAND
    eks_access
1EOF
}

eks_access () {
    ROLE_ARN=\$(aws sts get-caller-identity --query Arn --output text | cut -d '/' -f1,2 | sed 's/assumed-//' | sed 's/:sts:/:iam:/')
    echo \$ROLE_ARN

    if ! aws eks list-access-entries --cluster-name \$CLUSTER --query accessEntries | jq -e '. [] | select(. == "'\$ROLE_ARN'")' > /dev/null; then
        aws eks create-access-entry --cluster-name \$CLUSTER --principal-arn \$ROLE_ARN --no-cli-pager
        aws eks associate-access-policy --cluster-name \$CLUSTER --principal-arn \$ROLE_ARN --access-scope type=cluster --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --no-cli-pager
    fi

    aws eks update-kubeconfig --name \$CLUSTER
}

proxy () {
    docker rm -f sampler
    docker run -d --name sampler --restart always --network host --env UPSTREAM_ENDPOINT=\$1 public.ecr.aws/g1s2t7w5/sampler:latest
    docker ps
}

image_push () {
    REGION=\$(aws configure get region)

    if [ ! -f ~/.docker/config.json ]; then
        aws ecr get-login-password | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.\$REGION.amazonaws.com
    fi
    docker tag \$1 $AWS_ACCOUNT_ID.dkr.ecr.\$REGION.amazonaws.com/\$2
    docker push $AWS_ACCOUNT_ID.dkr.ecr.\$REGION.amazonaws.com/\$2
}

logs () {
    command=\$1
    if [ -z \$2 ]; then
        command="help"
    fi
    path1=\$2
    path2=\$3

    case \$command in
        recent) elb-log-analyzer \$path1 --limit 50  --col1 timestamp --col2 method --col3 requested_resource ;;
        status) elb-log-analyzer \$path1 --limit 25 --col2 method --col3 requested_resource.pathname --col4 elb_status_code --col5 backend_status_code ;;
        long) elb-log-analyzer \$path1 --limit 100 --col1 timestamp --col2 requested_resource --col3 total_time --sortBy 3 ;;
        sync) aws s3 sync \$2 \$3 && gzip -rd \$3 ;;
        *)
            echo "Usage: logs <recent|status|long|sync> PATH"
            echo "To sync logs, \"logs sync s3://bucket/path LOCAL_PATH\""
        ;;
    esac
}

daemonize () {
    COMMAND="\$*"
    _daemonize "\$COMMAND" 1
}

daemonize_without_logs () {
    COMMAND="\$*"
    _daemonize "\$COMMAND" 0
}

_daemonize () {
    if [ \$2 == 1 ]; then
        EXEC_START="/bin/bash -c '\$1 > >(tee /var/log/app/app.log) 2> >(tee /var/log/app/error.log >&2) < /dev/null'"
    else
        EXEC_START=\$1
    fi

    sudo mkdir -p /var/log/app
    sudo touch /var/log/app/app.log
    sudo touch /var/log/app/error.log

    echo "===== /etc/systemd/system/app.service ====="
    echo

    cat << 1EOF | sudo tee /etc/systemd/system/app.service
[Unit]
Description=application
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
WorkingDirectory=/opt/app
ExecStart=\$EXEC_START

[Install]
WantedBy=multi-user.target
1EOF

    sudo systemctl daemon-reload

    echo
    echo
    echo You can run \"sudo systemctl enable --now app\"
    echo "Also, don't forget \"sudo systemctl enable --now amazon-cloudwatch-agent\""
}
EOF
}

# Install and configure tools in OS specific ways
case $(uname -r) in
    *amzn2023*) configure_al2023 ;;
    *amzn2*) configure_al2 ;;
esac

# Common jobs
install_tools
install_k8s_tools
add_aws_region_warning
add_commands
