terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80.0"
    }
  }
}

# ============================================================
# Provider
# ============================================================
provider "aws" {
  region = "ap-south-1"
}

# ============================================================
# Local variables — consistent tags for every resource
# ============================================================
locals {
  common_tags = {
    Project     = "POC-ALB-Mumbai"
    Owner       = "Shubham"
    Environment = "poc"
    ManagedBy   = "Terraform"
    Region      = "ap-south-1"
  }
}

# ============================================================
# Security Group
# ============================================================
resource "aws_security_group" "poc_sg" {
  name        = "poc-sg-mumbai"
  description = "Allow SSH and HTTP"
  vpc_id      = "vpc-0c3b7e994ed25f944"

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "POC-SG-Mumbai" })
}

# ============================================================
# S3 Bucket for ALB Logs
# ============================================================
resource "aws_s3_bucket" "alb_logs_bucket" {
  bucket = "shubham-poc-alb-logs-mumbai"
  tags = merge(local.common_tags, { Name = "shubham-poc-alb-logs-mumbai" })
}

resource "aws_s3_bucket_acl" "alb_logs_acl" {
  bucket = aws_s3_bucket.alb_logs_bucket.id
  acl    = "private"
}

resource "aws_s3_bucket_ownership_controls" "alb_logs_owner" {
  bucket = aws_s3_bucket.alb_logs_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
  depends_on = [aws_s3_bucket_acl.alb_logs_acl]
}

resource "aws_s3_bucket_public_access_block" "alb_logs_block" {
  bucket                  = aws_s3_bucket.alb_logs_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  depends_on              = [aws_s3_bucket_ownership_controls.alb_logs_owner]
}

resource "aws_s3_bucket_policy" "alb_logs_policy" {
  bucket = aws_s3_bucket.alb_logs_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "AWSLogDeliveryWrite",
        Effect    = "Allow",
        Principal = { AWS = "arn:aws:iam::718504428378:root" },
        Action    = "s3:PutObject",
        Resource  = "arn:aws:s3:::shubham-poc-alb-logs-mumbai/alb-logs/AWSLogs/250063290357/*"
      },
      {
        Sid       = "AWSLogDeliveryAclCheck",
        Effect    = "Allow",
        Principal = { AWS = "arn:aws:iam::718504428378:root" },
        Action    = "s3:GetBucketAcl",
        Resource  = "arn:aws:s3:::shubham-poc-alb-logs-mumbai"
      },
      {
        Sid       = "RootAccountFullAccess",
        Effect    = "Allow",
        Principal = { AWS = "arn:aws:iam::250063290357:root" },
        Action    = "s3:*",
        Resource = [
          "arn:aws:s3:::shubham-poc-alb-logs-mumbai",
          "arn:aws:s3:::shubham-poc-alb-logs-mumbai/*"
        ]
      }
    ]
  })

  depends_on = [
    aws_s3_bucket_ownership_controls.alb_logs_owner,
    aws_s3_bucket_public_access_block.alb_logs_block
  ]
}

# ============================================================
# CloudWatch Log Group (Apache Logs)
# ============================================================
resource "aws_cloudwatch_log_group" "poc_log_group" {
  name              = "/poc/ec2/apache"
  retention_in_days = 7
  tags = merge(local.common_tags, { Name = "POC-LogGroup" })
}

# ============================================================
# Launch Template
# ============================================================
resource "aws_launch_template" "poc_lt" {
  name_prefix   = "poc-lt-mumbai-"
  image_id      = "ami-0f8ca728008ff5af4"
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.poc_sg.id]
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.poc_ec2_profile.name
  }
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    yum update -y
    yum install -y httpd amazon-cloudwatch-agent
    systemctl start httpd
    systemctl enable httpd
    echo "<h1>POC EC2 Instance Running in Mumbai</h1>" > /var/www/html/index.html

    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CWA
    {
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/var/log/httpd/access_log",
                "log_group_name": "/poc/ec2/apache",
                "log_stream_name": "{instance_id}/access_log"
              },
              {
                "file_path": "/var/log/httpd/error_log",
                "log_group_name": "/poc/ec2/apache",
                "log_stream_name": "{instance_id}/error_log"
              }
            ]
          }
        }
      }
    }
    CWA

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
  USERDATA
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, { Name = "POC-EC2-Mumbai-ASG" })
  }

  tags = merge(local.common_tags, { Name = "POC-LaunchTemplate-Mumbai" })
}

# ============================================================
# Application Load Balancer
# ============================================================
resource "aws_lb" "poc_alb" {
  name               = "poc-alb-mumbai"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.poc_sg.id]
  subnets            = ["subnet-03f333d006d3804df", "subnet-091b0d412e5587d56"]

  access_logs {
    bucket  = aws_s3_bucket.alb_logs_bucket.bucket
    prefix  = "alb-logs"
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "POC-ALB-Mumbai" })
  depends_on = [aws_s3_bucket_policy.alb_logs_policy]
}

# ============================================================
# Target Group
# ============================================================
resource "aws_lb_target_group" "poc_tg" {
  name     = "poc-tg-mumbai"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "vpc-0c3b7e994ed25f944"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.common_tags, { Name = "POC-TG-Mumbai" })
}

# ============================================================
# ALB Listener
# ============================================================
resource "aws_lb_listener" "poc_listener" {
  load_balancer_arn = aws_lb.poc_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.poc_tg.arn
  }
}

# ============================================================
# Auto Scaling Group
# ============================================================
resource "aws_autoscaling_group" "poc_asg" {
  name                      = "poc-asg-mumbai"
  min_size                  = 1
  max_size                  = 3
  desired_capacity          = 1
  vpc_zone_identifier       = ["subnet-03f333d006d3804df", "subnet-091b0d412e5587d56"]
  target_group_arns         = [aws_lb_target_group.poc_tg.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.poc_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "POC-ASG-Mumbai"
    propagate_at_launch = true
  }

  depends_on = [aws_iam_instance_profile.poc_ec2_profile]
}

# ============================================================
# Auto Scaling Policy — CPU Target Tracking at 70%
# ============================================================
resource "aws_autoscaling_policy" "poc_cpu_policy" {
  name                   = "poc-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.poc_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

# ============================================================
# WAF v2 Web ACL
# ============================================================
resource "aws_wafv2_web_acl" "poc_waf" {
  name  = "poc-waf-mumbai"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "poc-waf-mumbai"
    sampled_requests_enabled   = true
  }

  tags = merge(local.common_tags, { Name = "POC-WAF-Mumbai" })
}

resource "aws_wafv2_web_acl_association" "poc_waf_alb" {
  resource_arn = aws_lb.poc_alb.arn
  web_acl_arn  = aws_wafv2_web_acl.poc_waf.arn
}

# ============================================================
# CloudWatch Alarm — Unhealthy Targets
# ============================================================
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_targets" {
  alarm_name          = "POC-ALB-Unhealthy-Targets"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Alarm when ALB target group has unhealthy hosts"

  dimensions = {
    LoadBalancer = aws_lb.poc_alb.arn_suffix
    TargetGroup  = aws_lb_target_group.poc_tg.arn_suffix
  }

  actions_enabled = true
  alarm_actions   = ["arn:aws:sns:ap-south-1:250063290357:POC-ALB-Alerts"]
}

# ============================================================
# CloudWatch Alarm — 5XX Errors
# ============================================================
resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  alarm_name          = "POC-ALB-5XX-Errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Alarm when ALB generates 5XX errors"

  dimensions = {
    LoadBalancer = aws_lb.poc_alb.arn_suffix
  }

  actions_enabled = true
  alarm_actions   = ["arn:aws:sns:ap-south-1:250063290357:POC-ALB-Alerts"]
}

# ============================================================
# CloudWatch Alarm — 4XX Errors
# ============================================================
resource "aws_cloudwatch_metric_alarm" "alb_4xx_errors" {
  alarm_name          = "POC-ALB-4XX-Errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_4XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Alarm when ALB generates more than 10 4XX errors per minute"

  dimensions = {
    LoadBalancer = aws_lb.poc_alb.arn_suffix
  }

  actions_enabled = true
  alarm_actions   = ["arn:aws:sns:ap-south-1:250063290357:POC-ALB-Alerts"]
}

# ============================================================
# CloudWatch Alarm — High Latency (>2s)
# ============================================================
resource "aws_cloudwatch_metric_alarm" "alb_high_latency" {
  alarm_name          = "POC-ALB-High-Latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 2
  alarm_description   = "Alarm when ALB target response time exceeds 2 seconds"

  dimensions = {
    LoadBalancer = aws_lb.poc_alb.arn_suffix
  }

  actions_enabled = true
  alarm_actions   = ["arn:aws:sns:ap-south-1:250063290357:POC-ALB-Alerts"]
}

# ============================================================
# CloudWatch Dashboard
# ============================================================
resource "aws_cloudwatch_dashboard" "poc_alb_dashboard" {
  dashboard_name = "POC-ALB-Mumbai-Dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Total Request Count"
          view    = "timeSeries"
          region  = "ap-south-1"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.poc_alb.arn_suffix,
              { stat = "Sum", period = 60 }
            ]
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Healthy vs Unhealthy Targets"
          view   = "timeSeries"
          region = "ap-south-1"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount",
              "LoadBalancer", aws_lb.poc_alb.arn_suffix,
              "TargetGroup", aws_lb_target_group.poc_tg.arn_suffix,
              { stat = "Average", period = 60, color = "#2ca02c" }
            ],
            ["AWS/ApplicationELB", "UnHealthyHostCount",
              "LoadBalancer", aws_lb.poc_alb.arn_suffix,
              "TargetGroup", aws_lb_target_group.poc_tg.arn_suffix,
              { stat = "Average", period = 60, color = "#d62728" }
            ]
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "5XX Error Count"
          view    = "timeSeries"
          region  = "ap-south-1"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.poc_alb.arn_suffix,
              { stat = "Sum", period = 60, color = "#d62728" }
            ]
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "4XX Error Count"
          view    = "timeSeries"
          region  = "ap-south-1"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_4XX_Count", "LoadBalancer", aws_lb.poc_alb.arn_suffix,
              { stat = "Sum", period = 60, color = "#ff7f0e" }
            ]
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Target Response Time"
          view   = "timeSeries"
          region = "ap-south-1"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.poc_alb.arn_suffix,
              { stat = "Average", period = 60, color = "#1f77b4", label = "Avg" }
            ],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.poc_alb.arn_suffix,
              { stat = "p99", period = 60, color = "#9467bd", label = "p99" }
            ]
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 12
        width  = 24
        height = 4
        properties = {
          title = "Alarm Status Overview"
          alarms = [
            aws_cloudwatch_metric_alarm.alb_unhealthy_targets.arn,
            aws_cloudwatch_metric_alarm.alb_5xx_errors.arn,
            aws_cloudwatch_metric_alarm.alb_4xx_errors.arn,
            aws_cloudwatch_metric_alarm.alb_high_latency.arn
          ]
        }
      }
    ]
  })
}

# ============================================================
# IAM Role for EC2 (CloudWatch Logs + SSM access)
# ============================================================
resource "aws_iam_role" "poc_ec2_role" {
  name = "poc-ec2-role-mumbai"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "POC-EC2-Role" })
}

resource "aws_iam_role_policy_attachment" "poc_cw_logs" {
  role       = aws_iam_role.poc_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "poc_ssm" {
  role       = aws_iam_role.poc_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "poc_ec2_profile" {
  name = "poc-ec2-profile-mumbai"
  role = aws_iam_role.poc_ec2_role.name
}

# ============================================================
# Outputs
# ============================================================
output "alb_dns_name" {
  description = "ALB DNS — paste this in your browser to test"
  value       = aws_lb.poc_alb.dns_name
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix (used in CloudWatch metrics)"
  value       = aws_lb.poc_alb.arn_suffix
}

output "s3_bucket_name" {
  description = "S3 bucket storing ALB access logs"
  value       = aws_s3_bucket.alb_logs_bucket.bucket
}

output "cloudwatch_dashboard_url" {
  description = "Direct link to CloudWatch dashboard"
  value       = "https://ap-south-1.console.aws.amazon.com/cloudwatch/home?region=ap-south-1#dashboards:name=POC-ALB-Mumbai-Dashboard"
}

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.poc_asg.name
}

output "waf_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = aws_wafv2_web_acl.poc_waf.arn
}

output "log_group_name" {
  description = "CloudWatch Log Group for Apache logs"
  value       = aws_cloudwatch_log_group.poc_log_group.name
}
