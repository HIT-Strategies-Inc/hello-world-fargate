#!/bin/bash

echo "🔧 Deploying Hello World App to AWS Fargate"
echo "=========================================="

# Set AWS profile
export AWS_PROFILE="AdministratorAccess-905418315177"
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="905418315177"
REPO_NAME="hello-world-app"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}:latest"

# Step 1: Ensure Docker is running
echo "✅ Step 1: Checking Docker..."
if ! docker --version >/dev/null 2>&1; then
    echo "❌ Docker is not running. Please start Docker Desktop."
    exit 1
fi

# Step 2: Build and push Docker image
echo "🏗 Step 2: Building Docker image..."
docker build -t ${ECR_URI} /Users/jackguinan/Documents/OpenCode/hello-world-app

echo "📦 Step 3: Pushing to ECR..."
docker push ${ECR_URI}

# Step 3: Wait a moment for ECR to process
echo "⏳ Step 4: Waiting for ECR to process image..."
sleep 30

# Step 4: Update ECS service with new deployment
echo "🚀 Step 5: Deploying to ECS..."
aws ecs update-service \
  --cluster hello-world-cluster \
  --service hello-world-service \
  --task-definition hello-world-task-simple \
  --desired-count 1 \
  --force-new-deployment \
  --region ${AWS_REGION}

# Step 5: Wait for deployment to complete
echo "⏳ Step 6: Waiting for deployment to stabilize..."
aws ecs wait services-stable \
  --cluster hello-world-cluster \
  --services hello-world-service \
  --region ${AWS_REGION}

# Step 6: Get the ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names hello-world-alb \
  --region ${AWS_REGION} \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

echo ""
echo "✅ Deployment Complete!"
echo "=========================================="
echo "🌍 Your app is available at: http://${ALB_DNS}"
echo "🏥 Health check: http://${ALB_DNS}/health"
echo ""
echo "📊 Monitoring Commands:"
echo "  aws ecs describe-services --cluster hello-world-cluster --services hello-world-service --region ${AWS_REGION}"
echo "  aws logs tail /ecs/hello-world --follow --region ${AWS_REGION}"
echo "  aws ecs list-tasks --cluster hello-world-cluster --region ${AWS_REGION}"
echo ""
echo "🔧 To update deployment:"
echo "  ./deploy-hello-world.sh"