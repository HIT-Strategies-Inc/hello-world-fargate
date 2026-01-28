#!/bin/bash

# Complete the AWS Fargate deployment
set -e

export AWS_PROFILE="AdministratorAccess-905418315177"
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="905418315177"
REPO_NAME="hello-world-app"
SERVICE_NAME="hello-world-service"
CLUSTER_NAME="hello-world-cluster"
ECR_URI="905418315177.dkr.ecr.us-east-1.amazonaws.com/hello-world-app"

echo "=== Completing AWS Fargate Deployment ==="

# Get ALB details
ALB_ARN=$(aws elbv2 describe-load-balancers --names hello-world-alb --region $AWS_REGION --query 'LoadBalancers[0].LoadBalancerArn' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --names hello-world-alb --region $AWS_REGION --query 'LoadBalancers[0].DNSName' --output text)
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --names hello-world-tg --region $AWS_REGION --query 'TargetGroups[0].TargetGroupArn' --output text)
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
ALB_SG_ID="sg-08ae14fc95f64810f"
ECS_SG_ID="sg-0ecc6c4f69e844f1f"

# Get subnets
SUBNET_1=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=availability-zone,Values=us-east-1a" "Name=mapPublicIpOnLaunch,Values=true" --query 'Subnets[0].SubnetId' --output text --region $AWS_REGION)
SUBNET_2=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=availability-zone,Values=us-east-1b" "Name=mapPublicIpOnLaunch,Values=true" --query 'Subnets[0].SubnetId' --output text --region $AWS_REGION)

# Create listener if it doesn't exist
if ! aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --region $AWS_REGION | grep -q "Port: 80"; then
    echo "Creating ALB listener..."
    aws elbv2 create-listener \
      --load-balancer-arn $ALB_ARN \
      --protocol HTTP \
      --port 80 \
      --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
      --region $AWS_REGION
fi

# Create task definition
echo "Creating ECS task definition..."
cat > task-definition-final.json << EOF
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

TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json file://task-definition-final.json --region $AWS_REGION --query 'taskDefinition.taskDefinitionArn' --output text)

# Create or update service
if ! aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION | grep -q "ACTIVE"; then
    echo "Creating ECS service..."
    aws ecs create-service \
      --cluster $CLUSTER_NAME \
      --service-name $SERVICE_NAME \
      --task-definition $TASK_DEF_ARN \
      --desired-count 1 \
      --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$ECS_SG_ID],assignPublicIp=ENABLED}" \
      --load-balancers targetGroupArn=$TARGET_GROUP_ARN,containerName=hello-world-container,containerPort=3000 \
      --health-check-grace-period-seconds 60 \
      --region $AWS_REGION
    
    echo "Waiting for service to stabilize..."
    aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION
else
    echo "Updating existing ECS service..."
    aws ecs update-service --cluster $CLUSTER_NAME --service-name $SERVICE_NAME --task-definition $TASK_DEF_ARN --force-new-deployment --region $AWS_REGION
fi

# Create CloudWatch log group
aws logs create-log-group --log-group-name /ecs/hello-world --region $AWS_REGION || echo "Log group already exists"

echo ""
echo "=== Deployment Complete! ==="
echo "✅ Infrastructure ready"
echo "✅ Load Balancer: http://$ALB_DNS"
echo "✅ ECR Repository: $ECR_URI"
echo "✅ ECS Service: $SERVICE_NAME"
echo ""
echo "=== Docker Commands ==="
echo "docker build -t $ECR_URI:latest ."
echo "aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin \$ECR_URI"
echo "docker push \$ECR_URI:latest"
echo ""
echo "=== After pushing image, update service ==="
echo "aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force-new-deployment --region $AWS_REGION"
echo ""
echo "=== Check Logs ==="
echo "aws logs tail /ecs/hello-world --follow --region $AWS_REGION"
echo ""
echo "🌍 Your app will be available at: http://$ALB_DNS"