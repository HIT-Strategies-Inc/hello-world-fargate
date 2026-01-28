#!/bin/bash

# Load variables
source deployment_vars.sh

# Create Application Load Balancer
echo -e "${YELLOW}Creating Application Load Balancer...${NC}"
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name hello-world-alb \
  --subnets $(echo $PUBLIC_SUBNETS | tr ' ' ',') \
  --security-groups $ALB_SG_ID \
  --scheme internet-facing \
  --type application \
  --region $AWS_REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

echo "ALB ARN: $ALB_ARN"

# Get ALB DNS name (will be populated later)
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --region $AWS_REGION \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

echo "ALB DNS: $ALB_DNS"

# Create target group
echo -e "${YELLOW}Creating target group...${NC}"
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

# Create listener
echo -e "${YELLOW}Creating listener...${NC}"
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
  --region $AWS_REGION \
  --query 'Listeners[0].ListenerArn' \
  --output text)

echo "Listener ARN: $LISTENER_ARN"

# Wait for ALB to be ready
echo -e "${YELLOW}Waiting for ALB to be ready...${NC}"
aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN --region $AWS_REGION

# Update the variables file
cat >> deployment_vars.sh << EOF
export ALB_ARN="$ALB_ARN"
export ALB_DNS="$ALB_DNS"
export TARGET_GROUP_ARN="$TARGET_GROUP_ARN"
export LISTENER_ARN="$LISTENER_ARN"
EOF

echo -e "${GREEN}Load balancer setup complete!${NC}"
echo "ALB will be available at: http://$ALB_DNS"