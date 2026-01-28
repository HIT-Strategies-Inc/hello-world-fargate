#!/bin/bash

# Simplified AWS Fargate Deployment using CloudFormation
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
STACK_NAME="hello-world-stack"

echo -e "${GREEN}=== AWS CloudFormation Hello World Deployment ===${NC}"

# Step 1: Create CloudFormation template
echo -e "${YELLOW}Step 1: Creating CloudFormation template...${NC}"

cat > hello-world-template.yaml << 'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Hello World Web Application on Fargate'

Parameters:
  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC ID for the application
  
  SubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: At least two subnets for the load balancer

Resources:
  # ECR Repository
  ECRRepository:
    Type: AWS::ECR::Repository
    Properties:
      RepositoryName: hello-world-app
      ImageScanningConfiguration:
        ScanOnPush: false

  # ECS Cluster
  ECSCluster:
    Type: AWS::ECS::Cluster
    Properties:
      ClusterName: hello-world-cluster
      CapacityProviders:
        - FARGATE
        - FARGATE_SPOT

  # Application Load Balancer
  ApplicationLoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: hello-world-alb
      Scheme: internet-facing
      Type: application
      Subnets: !Ref SubnetIds
      SecurityGroups:
        - !Ref ALBSecurityGroup

  # ALB Security Group
  ALBSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for the Hello World ALB
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: 0.0.0.0/0

  # Target Group
  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: hello-world-tg
      Port: 3000
      Protocol: HTTP
      VpcId: !Ref VpcId
      TargetType: ip
      HealthCheckPath: /health
      HealthCheckIntervalSeconds: 30
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 3

  # ALB Listener
  ALBListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref ApplicationLoadBalancer
      Port: 80
      Protocol: HTTP
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup

  # ECS Security Group
  ECSSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for the Hello World ECS tasks
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 3000
          ToPort: 3000
          SourceSecurityGroupId: !GetAtt ALBSecurityGroup.GroupId

  # ECS Task Execution Role
  ECSTaskExecutionRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ecs-tasks.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

  # Task Definition
  TaskDefinition:
    Type: AWS::ECS::TaskDefinition
    Properties:
      Family: hello-world-task
      NetworkMode: awsvpc
      RequiresCompatibilities:
        - FARGATE
      Cpu: 256
      Memory: 512
      ExecutionRoleArn: !GetAtt ECSTaskExecutionRole.Arn
      ContainerDefinitions:
        - Name: hello-world-container
          Image: !Sub '${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com/hello-world-app:latest'
          PortMappings:
            - ContainerPort: 3000
              Protocol: tcp
          Environment:
            - Name: NODE_ENV
              Value: production
          LogConfiguration:
            LogDriver: awslogs
            Options:
              awslogs-group: /ecs/hello-world
              awslogs-region: !Ref AWS::Region
              awslogs-stream-prefix: ecs

  # ECS Service
  ECSService:
    Type: AWS::ECS::Service
    DependsOn:
      - ALBListener
    Properties:
      Cluster: !Ref ECSCluster
      ServiceName: hello-world-service
      TaskDefinition: !Ref TaskDefinition
      DesiredCount: 1
      LaunchType: FARGATE
      NetworkConfiguration:
        AwsvpcConfiguration:
          Subnets: !Ref SubnetIds
          SecurityGroups:
            - !Ref ECSSecurityGroup
          AssignPublicIp: ENABLED
      LoadBalancers:
        - TargetGroupArn: !Ref TargetGroup
          ContainerName: hello-world-container
          ContainerPort: 3000
      HealthCheckGracePeriodSeconds: 60

Outputs:
  LoadBalancerDNS:
    Description: DNS name of the load balancer
    Value: !GetAtt ApplicationLoadBalancer.DNSName
    Export:
      Name: !Sub '${AWS::StackName}-LoadBalancerDNS'
  
  ECRRepositoryURI:
    Description: ECR Repository URI
    Value: !GetAtt ECRRepository.RepositoryUri
    Export:
      Name: !Sub '${AWS::StackName}-ECRRepositoryURI'

EOF

echo "CloudFormation template created successfully."

# Step 2: Get VPC and subnet information
echo -e "${YELLOW}Step 2: Getting VPC and subnet information...${NC}"
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)

# Get subnets from different AZs
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=mapPublicIpOnLaunch,Values=true" --query 'Subnets[0:3].SubnetId' --output text --region $AWS_REGION | tr '\n' ',' | sed 's/,$//')

echo "VPC ID: $DEFAULT_VPC_ID"
echo "Subnet IDs: $SUBNET_IDS"

# Step 3: Deploy CloudFormation stack
echo -e "${YELLOW}Step 3: Deploying CloudFormation stack...${NC}"
STACK_ID=$(aws cloudformation create-stack \
  --stack-name $STACK_NAME \
  --template-body file://hello-world-template.yaml \
  --parameters \
    ParameterKey=VpcId,ParameterValue=$DEFAULT_VPC_ID \
    ParameterKey=SubnetIds,ParameterValue=\"$SUBNET_IDS\" \
  --capabilities CAPABILITY_IAM \
  --region $AWS_REGION \
  --query 'StackId' \
  --output text)

echo "Stack creation started: $STACK_ID"

# Step 4: Wait for stack creation
echo -e "${YELLOW}Step 4: Waiting for stack creation to complete...${NC}"
aws cloudformation wait stack-create-complete \
  --stack-name $STACK_NAME \
  --region $AWS_REGION

# Step 5: Get outputs
echo -e "${YELLOW}Step 5: Getting deployment outputs...${NC}"
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerDNS`].OutputValue' \
  --output text)

ECR_URI=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryURI`].OutputValue' \
  --output text)

echo -e "${GREEN}=== Infrastructure Deployment Complete! ===${NC}"
echo -e "${GREEN}Load Balancer DNS: http://$ALB_DNS${NC}"
echo -e "${GREEN}ECR Repository URI: $ECR_URI${NC}"

# Save deployment info
cat > deployment-info.sh << EOF
export AWS_PROFILE="AdministratorAccess-905418315177"
export ALB_DNS="$ALB_DNS"
export ECR_URI="$ECR_URI"
export STACK_NAME="$STACK_NAME"
EOF

echo ""
echo "Next steps:"
echo "1. Build and push your Docker image to ECR:"
echo "   docker build -t $ECR_URI:latest ."
echo "   aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin \$ECR_URI"
echo "   docker push \$ECR_URI:latest"
echo ""
echo "2. Update ECS service with new image:"
echo "   aws ecs update-service --cluster hello-world-cluster --service hello-world-service --force-new-deployment --region $AWS_REGION"
echo ""
echo "3. Your application will be available at: http://$ALB_DNS"