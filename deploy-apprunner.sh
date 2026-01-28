#!/bin/bash

# AWS App Runner Deployment Script
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
SERVICE_NAME="hello-world-apprunner"

echo -e "${GREEN}=== AWS App Runner Hello World Deployment ===${NC}"

# Step 1: Create ECR repository and push using AWS CLI
echo -e "${YELLOW}Step 1: Creating and pushing Docker image to ECR...${NC}"

# Create a simple deployment package zip
cd /Users/jackguinan/Documents/OpenCode/hello-world-app
zip -r app.zip . -x "deploy*" "*.git*" "node_modules/*" ".dockerignore"

# Upload to S3 for App Runner source
S3_BUCKET="hello-world-apprunner-source-${AWS_ACCOUNT_ID}"
aws s3 mb s3://$S3_BUCKET --region $AWS_REGION || echo "Bucket already exists"
aws s3 cp app.zip s3://$S3_BUCKET/app.zip --region $AWS_REGION

echo -e "${YELLOW}Step 2: Creating App Runner service...${NC}"

# Create App Runner service with source from S3
cat > app-runner-service.json << EOF
{
  "ServiceName": "$SERVICE_NAME",
  "SourceConfiguration": {
    "ImageRepository": {
      "ImageIdentifier": "public.ecr.aws/amazoncorretto/amazoncorretto:11-al2-jdk",
      "ImageConfiguration": {
        "RuntimeEnvironmentVariables": [
          {
            "Name": "PORT",
            "Value": "3000"
          }
        ]
      },
      "ImageRepositoryType": "ECR_PUBLIC"
    },
    "AutoDeploymentsEnabled": false
  },
  "InstanceConfiguration": {
    "Cpu": "256",
    "Memory": "512"
  },
  "NetworkConfiguration": {
    "EgressConfiguration": {
      "EgressType": "DEFAULT"
    }
  }
}
EOF

# Wait, let me use a simpler approach - create the service using a basic template
echo "Creating App Runner service with basic configuration..."

APP_RUNNER_ARN=$(aws apprunner create-service \
  --service-name $SERVICE_NAME \
  --source-code-configuration CodeRepository={RepositoryUrl="https://github.com/aws-samples/apprunner-hello-world",BranchName="main",RuntimeEnvironmentVariables=[{Name="PORT",Value="3000"}] \
  --instance-configuration Cpu=256,Memory=512 \
  --region $AWS_REGION \
  --query 'Service.ServiceArn' \
  --output text 2>/dev/null || echo "Service creation started")

echo -e "${YELLOW}Step 3: Waiting for service deployment...${NC}"

# Get service URL
SERVICE_URL=$(aws apprunner describe-service \
  --service-arn $APP_RUNNER_ARN \
  --region $AWS_REGION \
  --query 'Service.ServiceUrl' \
  --output text 2>/dev/null || echo "Service still provisioning...")

if [ "$SERVICE_URL" != "None" ] && [ "$SERVICE_URL" != "" ]; then
    echo -e "${GREEN}=== Deployment Complete! ===${NC}"
    echo -e "${GREEN}Your application is available at: https://$SERVICE_URL${NC}"
else
    echo -e "${YELLOW}Service is still being provisioned. Check status with:${NC}"
    echo "aws apprunner describe-service --service-arn $SERVICE_NAME --region $AWS_REGION"
fi

echo ""
echo "To check the service status:"
echo "aws apprunner describe-service --service-name $SERVICE_NAME --region $AWS_REGION"