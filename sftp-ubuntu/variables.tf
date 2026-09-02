variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use for authentication"
  type        = string
  default     = "CoreProdWorkloadAccount"
}

variable "environment" {
  description = "Deployment environment (e.g. prod, staging, dev)"
  type        = string
  default     = "prod"
}

variable "project" {
  description = "Project name used for tagging"
  type        = string
  default     = "sftp-server"
}

# ── Instance ──────────────────────────────────────────────────────────────────

variable "instance_name" {
  description = "Name tag applied to the EC2 instance"
  type        = string
  default     = "sftp-ubuntu"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID for ap-south-1. Leave empty to use the latest Ubuntu 22.04 LTS AMI (data source lookup)."
  type        = string
  default     = ""
}

# ── Storage ───────────────────────────────────────────────────────────────────

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 100
}

variable "root_volume_type" {
  description = "Root EBS volume type"
  type        = string
  default     = "gp3"
}

variable "root_volume_iops" {
  description = "Provisioned IOPS for gp3 root volume"
  type        = number
  default     = 3000
}

variable "root_volume_throughput" {
  description = "Throughput (MiB/s) for gp3 root volume"
  type        = number
  default     = 125
}

variable "root_volume_encrypted" {
  description = "Whether to encrypt the root EBS volume"
  type        = bool
  default     = true
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "VPC ID where the instance will be deployed"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for the SFTP instance"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH (port 22) into the instance"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_sftp_cidrs" {
  description = "List of CIDR blocks allowed to connect via SFTP (port 22)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ── Secrets Manager ───────────────────────────────────────────────────────────

variable "secret_name" {
  description = "Name of the AWS Secrets Manager secret that will store the SSH private key"
  type        = string
  default     = "sftp-ubuntu/ssh-private-key"
}

variable "secret_recovery_window" {
  description = "Number of days before a deleted secret can be permanently deleted (0 = immediate)"
  type        = number
  default     = 7
}

# ── IAM ───────────────────────────────────────────────────────────────────────

variable "iam_role_name" {
  description = "Name of the IAM role attached to the SFTP EC2 instance"
  type        = string
  default     = "sftp-ubuntu-ec2-role"
}

variable "iam_instance_profile" {
  description = "Name of the IAM instance profile attached to the SFTP EC2 instance"
  type        = string
  default     = "sftp-ubuntu-ec2-instance-profile"
}
