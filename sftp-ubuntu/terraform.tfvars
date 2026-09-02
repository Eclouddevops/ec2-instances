# ──────────────────────────────────────────────────────────────────────────────
# terraform.tfvars – SFTP Ubuntu EC2 Instance  |  AWS Mumbai (ap-south-1)
# AWS Account: 986788162487 (CoreProdWorkloadAccount)
# ──────────────────────────────────────────────────────────────────────────────

# AWS settings
aws_region  = "ap-south-1"
aws_profile = "CoreProdWorkloadAccount"
environment = "prod"
project     = "sftp-server"

# Instance
instance_name = "sftp-ubuntu"
instance_type = "t3.large"
ami_id        = "" # Leave empty to auto-select latest Ubuntu 22.04 LTS AMI

# Storage
root_volume_size       = 100
root_volume_type       = "gp3"
root_volume_iops       = 3000
root_volume_throughput = 125
root_volume_encrypted  = true

# ── REQUIRED: fill in your VPC and public subnet IDs ─────────────────────────
# Run the following to list your VPCs and subnets in Mumbai:
#   aws ec2 describe-vpcs --region ap-south-1 --profile CoreProdWorkloadAccount
#   aws ec2 describe-subnets --region ap-south-1 --profile CoreProdWorkloadAccount
vpc_id    = "vpc-xxxxxxxxxxxxxxxxx" # TODO: replace with your VPC ID
subnet_id = "subnet-xxxxxxxxxxxxxxxxx" # TODO: replace with a public subnet ID

# Networking – restrict these CIDRs to your trusted IP ranges in production
allowed_ssh_cidrs  = ["0.0.0.0/0"] # TODO: restrict to your IP/CIDR for security
allowed_sftp_cidrs = ["0.0.0.0/0"] # TODO: restrict to your IP/CIDR for security

# Secrets Manager
secret_name            = "sftp-ubuntu/ssh-private-key"
secret_recovery_window = 7
