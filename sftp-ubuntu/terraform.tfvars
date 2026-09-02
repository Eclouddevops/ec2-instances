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

# ── VPC and Subnet ────────────────────────────────────────────────────────────
vpc_id    = "vpc-0c58ac931eaffb988"    # TimesPro_VPC
subnet_id = "subnet-01a994d75450a2350" # TimesPro_PrivateSubnet_2

# Networking – restrict these CIDRs to your trusted IP ranges in production
allowed_ssh_cidrs  = ["0.0.0.0/0"]
allowed_sftp_cidrs = ["0.0.0.0/0"]

# Secrets Manager
secret_name            = "sftp-ubuntu/ssh-private-key"
secret_recovery_window = 7

# IAM Role
iam_role_name        = "sftp-ubuntu-ec2-role"
iam_instance_profile = "sftp-ubuntu-ec2-instance-profile"
