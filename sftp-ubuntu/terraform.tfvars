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
vpc_cidr  = "10.19.0.0/16"            # TimesPro_VPC CIDR
subnet_id = "subnet-05731234ce71b3a5f" # TimesPro_PublicSubnet_1 (ap-south-1a) – PUBLIC

# Networking
allowed_ssh_cidrs  = ["0.0.0.0/0"]
allowed_sftp_cidrs = ["0.0.0.0/0"]

# EC2 Instance Connect Endpoint
# preserve_client_ip = false means traffic appears to come from within the VPC
eice_preserve_client_ip = false

# Secrets Manager
secret_name            = "sftp-ubuntu/ssh-private-key"
secret_recovery_window = 7

# IAM Role
iam_role_name        = "sftp-ubuntu-ec2-role"
iam_instance_profile = "sftp-ubuntu-ec2-instance-profile"
