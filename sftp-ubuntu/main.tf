# ──────────────────────────────────────────────────────────────────────────────
# Data Sources
# ──────────────────────────────────────────────────────────────────────────────

# Lookup latest Ubuntu 22.04 LTS AMI in ap-south-1 when no explicit AMI is given
data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu_22_04.id
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH Key Pair  (TLS-generated, stored in Secrets Manager)
# ──────────────────────────────────────────────────────────────────────────────

resource "tls_private_key" "sftp_ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "sftp_key_pair" {
  key_name   = "${var.instance_name}-key"
  public_key = tls_private_key.sftp_ssh_key.public_key_openssh

  tags = {
    Name = "${var.instance_name}-key"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Secrets Manager – store private key
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "sftp_ssh_private_key" {
  name                    = var.secret_name
  description             = "SSH private key for ${var.instance_name} EC2 instance"
  recovery_window_in_days = var.secret_recovery_window

  tags = {
    Name = var.secret_name
  }
}

resource "aws_secretsmanager_secret_version" "sftp_ssh_private_key_value" {
  secret_id = aws_secretsmanager_secret.sftp_ssh_private_key.id
  secret_string = jsonencode({
    private_key = tls_private_key.sftp_ssh_key.private_key_pem
    public_key  = tls_private_key.sftp_ssh_key.public_key_openssh
    key_name    = aws_key_pair.sftp_key_pair.key_name
  })
}

# ──────────────────────────────────────────────────────────────────────────────
# Security Group – SSH inbound (used by EC2 Instance Connect Endpoint tunnel)
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "sftp_sg" {
  name        = "${var.instance_name}-sg"
  description = "Security group for SFTP/SSH access to ${var.instance_name}"
  vpc_id      = var.vpc_id

  # SSH inbound – source is the EC2 Instance Connect Endpoint SG
  # allowing traffic from eice_sg ensures only the EICE tunnel can reach port 22
  ingress {
    description     = "SSH via EC2 Instance Connect Endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice_sg.id]
  }

  # All outbound traffic (needed for apt-get, SSM agent, etc.)
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# Security Group for EC2 Instance Connect Endpoint itself
resource "aws_security_group" "eice_sg" {
  name        = "${var.instance_name}-eice-sg"
  description = "Security group for EC2 Instance Connect Endpoint"
  vpc_id      = var.vpc_id

  # No inbound rules needed on the endpoint SG
  # Outbound: allow SSH to the instance SG on port 22
  egress {
    description = "Allow SSH to SFTP instance"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-eice-sg"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# EC2 Instance Connect Endpoint (EICE)
# Allows SSH into a private-subnet instance with NO bastion, NO public IP
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_ec2_instance_connect_endpoint" "sftp_eice" {
  subnet_id          = var.subnet_id
  security_group_ids = [aws_security_group.eice_sg.id]
  preserve_client_ip = var.eice_preserve_client_ip

  tags = {
    Name = "${var.instance_name}-eice"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# SSM VPC Endpoints (allow SSM Session Manager without NAT Gateway)
# Three endpoints are required: ssm, ssmmessages, ec2messages
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "ssm_endpoint_sg" {
  name        = "${var.instance_name}-ssm-endpoint-sg"
  description = "Security group for SSM VPC interface endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from VPC CIDR for SSM endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-ssm-endpoint-sg"
  }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [var.subnet_id]
  security_group_ids  = [aws_security_group.ssm_endpoint_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.instance_name}-ssm-endpoint"
  }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [var.subnet_id]
  security_group_ids  = [aws_security_group.ssm_endpoint_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.instance_name}-ssmmessages-endpoint"
  }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [var.subnet_id]
  security_group_ids  = [aws_security_group.ssm_endpoint_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.instance_name}-ec2messages-endpoint"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# EC2 Instance
# NOTE: Private subnet – no public IP. Access via EICE or SSM Session Manager.
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_instance" "sftp_ubuntu" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  key_name                    = aws_key_pair.sftp_key_pair.key_name
  vpc_security_group_ids      = [aws_security_group.sftp_sg.id]
  associate_public_ip_address = false # private subnet – no public IP
  iam_instance_profile        = aws_iam_instance_profile.sftp_instance_profile.name

  # Root EBS volume – 100 GB gp3
  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size
    iops                  = var.root_volume_iops
    throughput            = var.root_volume_throughput
    encrypted             = var.root_volume_encrypted
    delete_on_termination = true

    tags = {
      Name = "${var.instance_name}-root-volume"
    }
  }

  # User data – install OpenSSH server, SSM agent and enable SFTP subsystem
  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y openssh-server

    # Install SSM Agent (Ubuntu 22.04)
    snap install amazon-ssm-agent --classic || true
    systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true
    systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent.service || true

    # Ensure SFTP subsystem is configured
    if ! grep -q "^Subsystem sftp" /etc/ssh/sshd_config; then
      echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> /etc/ssh/sshd_config
    fi

    systemctl enable ssh
    systemctl restart ssh
  EOF

  tags = {
    Name = var.instance_name
    Role = "sftp-server"
  }

  lifecycle {
    ignore_changes = [
      ami,
      user_data,
    ]
  }

  depends_on = [
    aws_vpc_endpoint.ssm,
    aws_vpc_endpoint.ssmmessages,
    aws_vpc_endpoint.ec2messages,
  ]
}

# ──────────────────────────────────────────────────────────────────────────────
# IAM Role + Instance Profile
# AdministratorAccess + SSM managed policy for Session Manager
# ──────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid     = "AllowEC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sftp_ec2_role" {
  name               = var.iam_role_name
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  description        = "IAM role for ${var.instance_name} EC2 instance - full AWS access"

  tags = {
    Name = var.iam_role_name
  }
}

# Full AWS access
resource "aws_iam_role_policy_attachment" "sftp_admin_access" {
  role       = aws_iam_role.sftp_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# SSM Session Manager (required even with AdministratorAccess for SSM agent registration)
resource "aws_iam_role_policy_attachment" "sftp_ssm_access" {
  role       = aws_iam_role.sftp_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Inline policy: Secrets Manager access for the SSH key secret
resource "aws_iam_role_policy" "sftp_secrets_access" {
  name = "${var.iam_role_name}-secrets-policy"
  role = aws_iam_role.sftp_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerSSHKey"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Resource = aws_secretsmanager_secret.sftp_ssh_private_key.arn
      },
      {
        Sid    = "EC2DescribeSelf"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "sftp_instance_profile" {
  name = var.iam_instance_profile
  role = aws_iam_role.sftp_ec2_role.name

  tags = {
    Name = var.iam_instance_profile
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Elastic IP – permanent static public IP
#
# NOTE: The instance is in a private subnet (no IGW route), so the EIP is
# allocated and associated but inbound internet traffic will NOT reach it
# unless your VPC has a NAT Gateway or the subnet has a route to an IGW.
# The EIP is permanent – it stays allocated even if the instance is stopped
# or replaced, ensuring the public IP never changes.
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_eip" "sftp_eip" {
  domain = "vpc"

  tags = {
    Name = "${var.instance_name}-eip"
    Role = "sftp-server"
  }

  lifecycle {
    # Prevent EIP from being destroyed and re-created (would change the IP)
    prevent_destroy = true
  }
}

resource "aws_eip_association" "sftp_eip_assoc" {
  instance_id   = aws_instance.sftp_ubuntu.id
  allocation_id = aws_eip.sftp_eip.id
}
