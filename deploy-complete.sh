#!/bin/bash

# AWS Fargate Complete Deployment Script
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

echo -e "${GREEN}=== AWS Fargate Hello World Deployment ===${NC}"

# Step 1: Get infrastructure information
echo -e "${YELLOW}Step 1: Getting infrastructure information...${NC}"
REPO_URI=$(aws ecr describe-repositories --repository-names $REPO_NAME --region $AWS_REGION --query 'repositories[0].repositoryUri' --output text)
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)

# Get subnets from different AZs
SUBNETS=($(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=mapPublicIpOnLaunch,Values=true" --query 'Subnets[*].[SubnetId,AvailabilityZone]' --output text --region $AWS_REGION | head -4))
SUBNET_1=${SUBNETS[0]}
SUBNET_2=${SUBNETS[2]}

# Get security groups
ALB_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=hello-world-alb-sg" --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION)
ECS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=hello-world-ecs-sg" --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION)

echo "Repository URI: $REPO_URI"
echo "VPC ID: $DEFAULT_VPC_ID"
echo "Subnets: $SUBNET_1, $SUBNET_2"
echo "ALB SG: $ALB_SG_ID"
echo "ECS SG: $ECS_SG_ID"

# Step 2: Create Application Load Balancer
echo -e "${YELLOW}Step 2: Creating Application Load Balancer...${NC}"
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name hello-world-alb \
  --subnets $SUBNET_1 $SUBNET_2 \
  --security-groups $ALB_SG_ID \
  --scheme internet-facing \
  --type application \
  --region $AWS_REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

echo "ALB ARN: $ALB_ARN"

# Wait for ALB to be ready
echo "Waiting for ALB to be ready..."
aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN --region $AWS_REGION

# Get ALB DNS name
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --region $AWS_REGION \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

echo "ALB DNS: $ALB_DNS"

# Step 3: Create target group
echo -e "${YELLOW}Step 3: Creating target group...${NC}"
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
  --name hello-world-tg \
  --protocol HTTP \
  --port 3000 \
  --vpc-id $DEFAULT_VPC_ID \
  --target-type ip \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --region $AWS_REGION \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

echo "Target Group ARN: $TARGET_GROUP_ARN"

# Step 4: Create listener
echo -e "${YELLOW}Step 4: Creating listener...${NC}"
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
  --region $AWS_REGION \
  --query 'Listeners[0].ListenerArn' \
  --output text)

echo "Listener ARN: $LISTENER_ARN"

# Step 5: Create ECS task definition
echo -e "${YELLOW}Step 5: Creating ECS task definition...${NC}"
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
      "image": "$REPO_URI:latest",
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

# Register task definition
TASK_DEFINITION_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://task-definition.json \
  --region $AWS_REGION \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

echo "Task Definition ARN: $TASK_DEFINITION_ARN"

# Step 6: Create ECS service
echo -e "${YELLOW}Step 6: Creating ECS service...${NC}"
SERVICE_ARN=$(aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $SERVICE_NAME \
  --task-definition $TASK_DEFINITION_ARN \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$ECS_SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers targetGroupArn=$TARGET_GROUP_ARN,containerName=hello-world-container,containerPort=3000 \
  --health-check-grace-period-seconds 60 \
  --region $AWS_REGION \
  --query 'service.serviceArn' \
  --output text)

echo "Service ARN: $SERVICE_ARN"

# Step 7: Wait for service to be stable
echo -e "${YELLOW}Step 7: Waiting for service to stabilize...${NC}"
aws ecs wait services-stable \
  --cluster $CLUSTER_NAME \
  --services $SERVICE_NAME \
  --region $AWS_REGION

# Save variables
cat > deployment_complete.sh << EOF
export AWS_PROFILE="AdministratorAccess-905418315177"
export ALB_DNS="$ALB_DNS"
export CLUSTER_NAME="$CLUSTER_NAME"
export SERVICE_NAME="$SERVICE_NAME"
EOF

echo -e "${GREEN}=== Deployment Complete! ===${NC}"
echo -e "${GREEN}Your application is available at: http://$ALB_DNS${NC}"
echo ""
echo "To check the service status:"
echo "aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION"
echo ""
echo "To view logs:"
echo "aws logs tail /ecs/hello-world --follow --region $AWS_REGION"