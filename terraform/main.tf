terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      version = ">= 5.68"
      source  = "hashicorp/aws"
    }
  }
  backend "s3" {
    bucket = "sic-terraform-statefiles"
    region = "us-east-2"
  }
}

provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = {
      ManagedBy   = "Terraform"
      StateFile   = "s3://sic-terraform-statefiles/sic/calcom/${var.environment}/terraform.tfstate"
      Environment = var.environment
    }
  }
}

locals {
  definition_secrets = [
    for key, _ in jsondecode(data.aws_secretsmanager_secret_version.env.secret_string) :
    { name = key, valueFrom = "${data.aws_secretsmanager_secret.env.arn}:${key}::" }
  ]

  container_definition = {
    name  = "calcom-web"
    image = "289236010466.dkr.ecr.us-east-2.amazonaws.com/sic-calcom:${data.aws_ssm_parameter.image_tag.value}"
    cpu   = 2048
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-create-group  = "true"
        awslogs-group         = "/ecs/sic/calcom"
        awslogs-region        = "us-east-2"
        awslogs-stream-prefix = "web"
      }
      secretOptions = []
    }
    portMappings = [
      {
        name          = "calcom-web-listener"
        containerPort = 3000
        hostPort      = 3000
        protocol      = "tcp"
        appProtocol   = "http"
      }
    ]
    essential      = true
    environment    = []
    mountPoints    = []
    volumesFrom    = []
    systemControls = []
    secrets        = local.definition_secrets
  }

  ecs_cluster_arn               = data.terraform_remote_state.sic.outputs.ecs_cluster_arn
  ecs_cluster_load_balancer_arn = data.terraform_remote_state.sic.outputs.ecs_cluster_load_balancer_arn
}

data "terraform_remote_state" "sic" {
  backend = "s3"
  config = {
    bucket = "sic-terraform-statefiles"
    key    = "sic/prod/terraform.tfstate"
    region = "us-east-2"
  }
}

data "aws_caller_identity" "me" {}

data "aws_ssm_parameter" "image_tag" {
  name = "/sic/calcom/prod/image-tag"
}

data "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }

  filter {
    name   = "tag:Name"
    values = ["Private subnet *"]
  }
}

data "aws_secretsmanager_secret" "env" {
  name = "sic/calcom/prod/env"
}

data "aws_secretsmanager_secret_version" "env" {
  secret_id = data.aws_secretsmanager_secret.env.id
}

data "aws_acm_certificate" "calcom" {
  domain   = "cal.cogonation.com"
  statuses = ["ISSUED"]
}

# Look up the existing HTTPS listener on the shared ALB (created by the sic-node terraform)
data "aws_lb_listener" "https" {
  load_balancer_arn = local.ecs_cluster_load_balancer_arn
  port              = 443
}

# Look up the existing IAM execution role (created by the sic-node terraform)
data "aws_iam_role" "ecs_task" {
  name = "GeneralECSTaskDefinitionExecutionRole"
}

# Attach the cogonation cert to the shared HTTPS listener
resource "aws_lb_listener_certificate" "calcom" {
  listener_arn    = data.aws_lb_listener.https.arn
  certificate_arn = data.aws_acm_certificate.calcom.arn
}

# Target group for the Cal.com ECS service
resource "aws_lb_target_group" "calcom" {
  name        = "calcom-ingress"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 3
    interval            = 30
    matcher             = "200-499"
    path                = "/api/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 10
    unhealthy_threshold = 3
  }

  tags = {
    Name = "calcom-ingress"
  }
}

# Route cal.cogonation.com traffic to the Cal.com target group
resource "aws_lb_listener_rule" "calcom" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.calcom.arn
  }

  condition {
    host_header {
      values = ["cal.cogonation.com"]
    }
  }

  tags = {
    Name = "calcom-host-rule"
  }
}

# Security group for the Cal.com ECS container
resource "aws_security_group" "calcom" {
  name        = "calcom-container-sg"
  description = "Access rules for the Cal.com container."
  vpc_id      = data.aws_vpc.main.id

  tags = {
    Name = "calcom-container-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "calcom_in" {
  security_group_id = aws_security_group.calcom.id
  description       = "Cal.com HTTP port from ALB"
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "calcom-web-listener"
  }
}

resource "aws_vpc_security_group_egress_rule" "calcom_out" {
  security_group_id = aws_security_group.calcom.id
  description       = "outbound communication everywhere"
  from_port         = -1
  to_port           = -1
  ip_protocol       = "all"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "outbound everywhere"
  }
}

resource "aws_ecs_task_definition" "calcom" {
  family                   = "sic-calcom"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 2048
  memory                   = 4096
  execution_role_arn       = data.aws_iam_role.ecs_task.arn
  task_role_arn            = data.aws_iam_role.ecs_task.arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([local.container_definition])

  tags = {
    Name = "sic-calcom"
  }
}

resource "aws_ecs_service" "calcom" {
  name            = "calcom-service"
  cluster         = local.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.calcom.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.calcom.arn
    container_name   = "calcom-web"
    container_port   = 3000
  }

  network_configuration {
    assign_public_ip = false
    security_groups  = [aws_security_group.calcom.id]
    subnets          = data.aws_subnets.private.ids
  }

  service_connect_configuration {
    enabled = true
  }

  tags = {
    Name = "calcom-service"
  }
}
