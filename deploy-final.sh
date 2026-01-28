#!/bin/bash

# Final deployment script using existing resources
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

echo -e "${GREEN}=== Final Fargate Deployment ===${NC}"

# Get existing resources
echo -e "${YELLOW}Using existing infrastructure...${NC}"
ECR_URI=$(aws ecr describe-repositories --repository-names $REPO_NAME --region $AWS_REGION --query 'repositories[0].repositoryUri' --output text)
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
ALB_SG_ID="sg-08ae14fc95f64810f"
ECS_SG_ID="sg-0ecc6c4f69e844f1f"

# Get subnets from different AZs
SUBNET_1=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=availability-zone,Values=us-east-1a" "Name=mapPublicIpOnLaunch,Values=true" --query 'Subnets[0].SubnetId' --output text --region $AWS_REGION)
SUBNET_2=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=availability-zone,Values=us-east-1b" "Name=mapPublicIpOnLaunch,Values=true" --query 'Subnets[0].SubnetId' --output text --region $AWS_REGION)

echo "ECR URI: $ECR_URI"
echo "Subnets: $SUBNET_1, $SUBNET_2"

# Check if Load Balancer exists
if ! aws elbv2 describe-load-balancers --names hello-world-alb --region $AWS_REGION >/dev/null 2>&1; then
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
    
    aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN --region $AWS_REGION
    ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --region $AWS_REGION --query 'LoadBalancers[0].DNSName' --output text)
else
    ALB_ARN=$(aws elbv2 describe-load-balancers --names hello-world-alb --region $AWS_REGION --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    ALB_DNS=$(aws elbv2 describe-load-balancers --names hello-world-alb --region $AWS_REGION --query 'LoadBalancers[0].DNSName' --output text)
    echo "Using existing Load Balancer: $ALB_DNS"
fi

# Check if target group exists
if ! aws elbv2 describe-target-groups --names hello-world-tg --region $AWS_REGION >/dev/null 2>&1; then
    echo -e "${YELLOW}Creating target group...${NC}"
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
else
    TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --names hello-world-tg --region $AWS_REGION --query 'TargetGroups[0].TargetGroupArn' --output text)
    echo "Using existing target group"
fi

# Check if listener exists
if ! aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --region $AWS_REGION | grep -q "Port: 80"; then
    echo -e "${YELLOW}Creating listener...${NC}"
    aws elbv2 create-listener \
      --load-balancer-arn $ALB_ARN \
      --protocol HTTP \
      --port 80 \
      --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
      --region $AWS_REGION
fi

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
if ! aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION | grep -q "ACTIVE"; then
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
    
    echo -e "${YELLOW}Waiting for service to stabilize...${NC}"
    aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION
else
    echo "Service already exists, updating task definition..."
    aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --task-definition $TASK_DEF_ARN --force-new-deployment --region $AWS_REGION
fi

# Create deployment info file
cat > deployment-final.sh << EOF
export AWS_PROFILE="AdministratorAccess-905418315177"
export ALB_DNS="$ALB_DNS"
export ECR_URI="$ECR_URI"
export CLUSTER_NAME="$CLUSTER_NAME"
export SERVICE_NAME="$SERVICE_NAME"
export AWS_REGION="$AWS_REGION"
EOF

echo -e "${GREEN}=== Deployment Infrastructure Ready! ===${NC}"
echo -e "${GREEN}Load Balancer DNS: http://$ALB_DNS${NC}"
echo -e "${GREEN}ECR Repository: $ECR_URI${NC}"
echo ""
echo -e "${YELLOW}Docker Commands (once Docker is installed):${NC}"
echo "docker build -t $ECR_URI:latest ."
echo "aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin \$ECR_URI"
echo "docker push \$ECR_URI:latest"
echo ""
echo -e "${YELLOW}Update Service:${NC}"
echo "aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force-new-deployment --region $AWS_REGION"
echo ""
echo -e "${YELLOW}Check Logs:${NC}"
echo "aws logs tail /ecs/hello-world --follow --region $AWS_REGION"
echo ""
echo -e "${GREEN}Your app will be available at: http://$ALB_DNS${NC}"