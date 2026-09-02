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
# Security Group
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "sftp_sg" {
  name        = "${var.instance_name}-sg"
  description = "Security group for SFTP/SSH access to ${var.instance_name}"
  vpc_id      = var.vpc_id

  # SSH inbound
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # All outbound traffic
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

# ──────────────────────────────────────────────────────────────────────────────
# EC2 Instance
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_instance" "sftp_ubuntu" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  key_name                    = aws_key_pair.sftp_key_pair.key_name
  vpc_security_group_ids      = [aws_security_group.sftp_sg.id]
  associate_public_ip_address = true
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

  # User data – install OpenSSH server and enable SFTP subsystem
  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y openssh-server

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
      # Ignore AMI changes after initial creation
      ami,
      # Ignore user_data changes after initial creation to avoid replacement
      user_data,
    ]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# IAM Role + Instance Profile  (full EC2 + Secrets Manager access)
# ──────────────────────────────────────────────────────────────────────────────

# Trust policy – allows EC2 service to assume this role
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

# IAM Role
resource "aws_iam_role" "sftp_ec2_role" {
  name               = var.iam_role_name
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  description        = "IAM role for ${var.instance_name} EC2 instance - full AWS access"

  tags = {
    Name = var.iam_role_name
  }
}

# Attach AWS-managed AdministratorAccess policy (full access)
resource "aws_iam_role_policy_attachment" "sftp_admin_access" {
  role       = aws_iam_role.sftp_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Inline policy: explicit Secrets Manager access for the SSH key secret
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

# EC2 Instance Profile – wraps the role so it can be attached to the instance
resource "aws_iam_instance_profile" "sftp_instance_profile" {
  name = var.iam_instance_profile
  role = aws_iam_role.sftp_ec2_role.name

  tags = {
    Name = var.iam_instance_profile
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Elastic IP  (static public IP for external access)
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_eip" "sftp_eip" {
  instance = aws_instance.sftp_ubuntu.id
  domain   = "vpc"

  tags = {
    Name = "${var.instance_name}-eip"
  }

  depends_on = [aws_instance.sftp_ubuntu]
}
