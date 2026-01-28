#!/bin/bash

# AWS Hello World Fargate Deployment Script
set -e

# Variables
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="905418315177"
REPO_NAME="hello-world-app"
SERVICE_NAME="hello-world-service"
CLUSTER_NAME="hello-world-cluster"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting AWS Fargate deployment...${NC}"

# Create ECR repository if it doesn't exist
echo -e "${YELLOW}Creating ECR repository...${NC}"
aws ecr create-repository --repository-name $REPO_NAME --region $AWS_REGION || echo "Repository already exists"

# Get repository URI
REPO_URI=$(aws ecr describe-repositories --repository-names $REPO_NAME --region $AWS_REGION --query 'repositories[0].repositoryUri' --output text)
echo "Repository URI: $REPO_URI"

# Create ECS cluster
echo -e "${YELLOW}Creating ECS cluster...${NC}"
aws ecs create-cluster --cluster-name $CLUSTER_NAME --region $AWS_REGION || echo "Cluster already exists"

# Get VPC and subnet information
echo -e "${YELLOW}Getting VPC information...${NC}"
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
PUBLIC_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=mapPublicIpOnLaunch,Values=true" --query 'Subnets[*].SubnetId' --output text --region $AWS_REGION)

echo "VPC: $DEFAULT_VPC_ID"
echo "Public Subnets: $PUBLIC_SUBNETS"

# Create security group for the load balancer
echo -e "${YELLOW}Creating security group for load balancer...${NC}"
ALB_SG_ID=$(aws ec2 create-security-group --group-name "hello-world-alb-sg" --description "Security group for Hello World ALB" --vpc-id $DEFAULT_VPC_ID --region $AWS_REGION --query 'GroupId' --output text)

# Allow HTTP traffic to ALB
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $AWS_REGION

# Create security group for ECS tasks
echo -e "${YELLOW}Creating security group for ECS tasks...${NC}"
ECS_SG_ID=$(aws ec2 create-security-group --group-name "hello-world-ecs-sg" --description "Security group for Hello World ECS tasks" --vpc-id $DEFAULT_VPC_ID --region $AWS_REGION --query 'GroupId' --output text)

# Allow traffic from ALB to ECS tasks
aws ec2 authorize-security-group-ingress --group-id $ECS_SG_ID --protocol tcp --port 3000 --source-group $ALB_SG_ID --region $AWS_REGION

echo -e "${GREEN}Security groups created: ALB SG: $ALB_SG_ID, ECS SG: $ECS_SG_ID${NC}"

echo -e "${YELLOW}Infrastructure setup complete. Next steps:${NC}"
echo "1. Build and push Docker image to ECR"
echo "2. Create Application Load Balancer"
echo "3. Create ECS task definition and service"
echo "4. Deploy the application"

# Save variables for next steps
cat > deployment_vars.sh << EOF
export AWS_REGION="$AWS_REGION"
export AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID"
export REPO_NAME="$REPO_NAME"
export REPO_URI="$REPO_URI"
export CLUSTER_NAME="$CLUSTER_NAME"
export SERVICE_NAME="$SERVICE_NAME"
export DEFAULT_VPC_ID="$DEFAULT_VPC_ID"
export ALB_SG_ID="$ALB_SG_ID"
export ECS_SG_ID="$ECS_SG_ID"
EOF

echo -e "${GREEN}Variables saved to deployment_vars.sh${NC}"
echo "Run 'source deployment_vars.sh' before proceeding with the next steps."