terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = "ap-south-1"
  profile = "default"
}

# --- Data Sources ---
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Look up your existing Route53 Zone
data "aws_route53_zone" "main" {
  name         = "nextunitech.com"
  private_zone = false
}

# --- 1. Security Groups (The Critical Fixes) ---

# A. Load Balancer Security Group (Public Facing)
resource "aws_security_group" "alb_sg" {
  name        = "nextunitech-alb-sg"
  description = "Allow public HTTP/HTTPS to Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# B. Kubernetes Node Security Group (Private-ish)
resource "aws_security_group" "k8s_sg" {
  name        = "k8s-node-sg"
  description = "Security group for Kubernetes nodes"
  vpc_id      = data.aws_vpc.default.id

  # --- CRITICAL FIX: Self-Referencing Rule ---
  # This allows Pod-to-Pod communication (Fixes the 504 Gateway Timeouts)
  ingress {
    description = "Allow all internal traffic between nodes/pods"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true 
  }

  # --- Admin Access ---
  ingress {
    description = "SSH Access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Recommended: Restrict to your specific IP
  }

  # --- Traffic from Load Balancer Only ---
  ingress {
    description     = "Allow ALB to hit NodePorts"
    from_port       = 30000
    to_port         = 32767
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # Security Group Chaining
  }

  # --- Egress ---
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "k8s-node-sg"
  }
}

# --- 2. Compute Resources ---

resource "aws_key_pair" "k8s_key" {
  key_name   = "k8s-key"
  # Ensure this path is valid on the machine running Terraform
  public_key = file("") 
}

resource "aws_instance" "k8s_nodes" {
  count                  = 3
  ami                    = "ami-02d26659fd82cf299"
  instance_type          = "t3.medium"
  key_name               = aws_key_pair.k8s_key.key_name
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]

  root_block_device {
    volume_size = 20 # Increased for Docker images/logs
  }

  tags = {
    Name = "k8s-node-${count.index + 1}"
    Role = count.index == 0 ? "control-plane" : "worker"
  }
}

# --- 3. Load Balancer & SSL (The "Production" Setup) ---

# A. The Certificate
resource "aws_acm_certificate" "cert" {
  domain_name       = "nextunitech.com"
  validation_method = "DNS"
  subject_alternative_names = ["*.nextunitech.com"]

  lifecycle {
    create_before_destroy = true
  }
}

# B. The Load Balancer
resource "aws_lb" "main" {
  name               = "nextunitech-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

# C. Target Group 
# NOTE: After applying, you must patch your K8s Ingress Service to use 'nodePort: 30080'
resource "aws_lb_target_group" "k8s_tg" {
  name     = "nextunitech-tg"
  port     = 30080 # We will force K8s Ingress to listen on this specific port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path    = "/healthz" # Standard k8s ingress health check
    matcher = "200,404"  # 404 is fine for default backend
  }
}

# Attach Instances to Target Group
resource "aws_lb_target_group_attachment" "k8s_nodes_attachment" {
  count            = length(aws_instance.k8s_nodes)
  target_group_arn = aws_lb_target_group.k8s_tg.arn
  target_id        = aws_instance.k8s_nodes[count.index].id
  port             = 30080
}

# D. Listeners (HTTP -> HTTPS Redirect)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# E. Listener (HTTPS)
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_tg.arn
  }
}

# --- 4. DNS (Route53) ---

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "www.nextunitech.com"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "nextunitech.com"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# DNS Validation Record for ACM
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => dvo
  }

  allow_overwrite = true
  name            = each.value.resource_record_name
  records         = [each.value.resource_record_value]
  ttl             = 60
  type            = each.value.resource_record_type
  zone_id         = data.aws_route53_zone.main.zone_id
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}