#!/bin/bash

# Simple AWS Fargate Deployment using existing infrastructure
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set AWS profile
export AWS_PROFILE="AdministratorAccess-905418315177"

# Variables
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="905418315177"
REPO_NAME="hello-world-app"
SERVICE_NAME="hello-world-service"
CLUSTER_NAME="hello-world-cluster"

echo -e "${GREEN}=== Simple Fargate Deployment ===${NC}"

# Get existing resources
echo -e "${YELLOW}Getting existing infrastructure...${NC}"
ECR_URI=$(aws ecr describe-repositories --repository-names $REPO_NAME --region $AWS_REGION --query 'repositories[0].repositoryUri' --output text)
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)

# Get subnets from different AZs
SUBNET_1=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=availability-zone,Values=us-east-1a" "Name=mapPublicIpOnLaunch,Values=true" --query 'Subnets[0].SubnetId' --output text --region $AWS_REGION)
SUBNET_2=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=availability-zone,Values=us-east-1b" "Name=mapPublicIpOnLaunch,Values=true" --query 'Subnets[0].SubnetId' --output text --region $AWS_REGION)

echo "ECR URI: $ECR_URI"
echo "Subnets: $SUBNET_1, $SUBNET_2"

# Create security groups
echo -e "${YELLOW}Creating security groups...${NC}"
ALB_SG_ID=$(aws ec2 create-security-group --group-name "hello-world-alb-sg" --description "Security group for Hello World ALB" --vpc-id $DEFAULT_VPC_ID --region $AWS_REGION --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $AWS_REGION

ECS_SG_ID=$(aws ec2 create-security-group --group-name "hello-world-ecs-sg" --description "Security group for Hello World ECS tasks" --vpc-id $DEFAULT_VPC_ID --region $AWS_REGION --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $ECS_SG_ID --protocol tcp --port 3000 --source-group $ALB_SG_ID --region $AWS_REGION

# Create Load Balancer
echo -e "${YELLOW}Creating Load Balancer...${NC}"
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name hello-world-alb \
  --subnets $SUBNET_1 $SUBNET_2 \
  --security-groups $ALB_SG_ID \
  --scheme internet-facing \
  --type application \
  --region $AWS_REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

# Wait for ALB to be ready
aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN --region $AWS_REGION

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --region $AWS_REGION \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

# Create target group
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
  --name hello-world-tg \
  --protocol HTTP \
  --port 3000 \
  --vpc-id $DEFAULT_VPC_ID \
  --target-type ip \
  --health-check-path /health \
  --region $AWS_REGION \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

# Create listener
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
  --region $AWS_REGION

# Create task definition
echo -e "${YELLOW}Creating task definition...${NC}"
cat > task-definition.json << EOF
{
  "family": "hello-world-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "hello-world-container",
      "image": "$ECR_URI:latest",
      "portMappings": [
        {
          "containerPort": 3000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "NODE_ENV",
          "value": "production"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/hello-world",
          "awslogs-region": "$AWS_REGION",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
EOF

TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json file://task-definition.json --region $AWS_REGION --query 'taskDefinition.taskDefinitionArn' --output text)

# Create service
echo -e "${YELLOW}Creating ECS service...${NC}"
SERVICE_ARN=$(aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $SERVICE_NAME \
  --task-definition $TASK_DEF_ARN \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$ECS_SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers targetGroupArn=$TARGET_GROUP_ARN,containerName=hello-world-container,containerPort=3000 \
  --health-check-grace-period-seconds 60 \
  --region $AWS_REGION \
  --query 'service.serviceArn' \
  --output text)

# Wait for service to stabilize
echo -e "${YELLOW}Waiting for service to stabilize...${NC}"
aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION

# Create deployment info file
cat > deployment-complete.sh << EOF
export AWS_PROFILE="AdministratorAccess-905418315177"
export ALB_DNS="$ALB_DNS"
export ECR_URI="$ECR_URI"
export CLUSTER_NAME="$CLUSTER_NAME"
export SERVICE_NAME="$SERVICE_NAME"
EOF

echo -e "${GREEN}=== Deployment Infrastructure Ready! ===${NC}"
echo -e "${GREEN}Load Balancer DNS: http://$ALB_DNS${NC}"
echo -e "${GREEN}ECR Repository: $ECR_URI${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Install Docker (waiting for installation to complete)"
echo "2. Build and push Docker image:"
echo "   docker build -t $ECR_URI:latest ."
echo "   aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin \$ECR_URI"
echo "   docker push \$ECR_URI:latest"
echo ""
echo "3. Update service:"
echo "   aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force-new-deployment --region $AWS_REGION"
echo ""
echo -e "${GREEN}Your app will be available at: http://$ALB_DNS${NC}"