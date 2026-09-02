# ──────────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────────

output "instance_id" {
  description = "EC2 instance ID of the SFTP server"
  value       = aws_instance.sftp_ubuntu.id
}

output "instance_private_ip" {
  description = "Private IP address of the SFTP instance"
  value       = aws_instance.sftp_ubuntu.private_ip
}

output "instance_public_ip" {
  description = "Elastic (public) IP address assigned to the SFTP instance"
  value       = aws_eip.sftp_eip.public_ip
}

output "instance_public_dns" {
  description = "Public DNS hostname of the SFTP instance"
  value       = aws_instance.sftp_ubuntu.public_dns
}

output "security_group_id" {
  description = "ID of the security group attached to the SFTP instance"
  value       = aws_security_group.sftp_sg.id
}

output "key_pair_name" {
  description = "Name of the EC2 key pair used for SSH access"
  value       = aws_key_pair.sftp_key_pair.key_name
}

output "ssh_private_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the SSH private key"
  value       = aws_secretsmanager_secret.sftp_ssh_private_key.arn
}

output "ssh_private_key_secret_name" {
  description = "Name of the Secrets Manager secret holding the SSH private key"
  value       = aws_secretsmanager_secret.sftp_ssh_private_key.name
}

output "ami_id_used" {
  description = "AMI ID used to launch the instance"
  value       = local.ami_id
}

output "ssh_connection_command" {
  description = "SSH command to connect to the SFTP instance (after retrieving the key from Secrets Manager)"
  value       = "ssh -i <private_key_file> ubuntu@${aws_eip.sftp_eip.public_ip}"
}

output "retrieve_key_command" {
  description = "AWS CLI command to retrieve the SSH private key from Secrets Manager"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.sftp_ssh_private_key.name} --profile CoreProdWorkloadAccount --region ap-south-1 --query SecretString --output text | jq -r '.private_key' > sftp-ubuntu.pem && chmod 400 sftp-ubuntu.pem"
}

# ── IAM Outputs ───────────────────────────────────────────────────────────────

output "iam_role_name" {
  description = "Name of the IAM role attached to the SFTP EC2 instance"
  value       = aws_iam_role.sftp_ec2_role.name
}

output "iam_role_arn" {
  description = "ARN of the IAM role attached to the SFTP EC2 instance"
  value       = aws_iam_role.sftp_ec2_role.arn
}

output "iam_instance_profile_name" {
  description = "Name of the IAM instance profile attached to the SFTP EC2 instance"
  value       = aws_iam_instance_profile.sftp_instance_profile.name
}

output "iam_instance_profile_arn" {
  description = "ARN of the IAM instance profile attached to the SFTP EC2 instance"
  value       = aws_iam_instance_profile.sftp_instance_profile.arn
}
