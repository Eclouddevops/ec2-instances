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

output "security_group_id" {
  description = "ID of the security group attached to the SFTP instance"
  value       = aws_security_group.sftp_sg.id
}

output "eice_sg_id" {
  description = "ID of the EC2 Instance Connect Endpoint security group"
  value       = aws_security_group.eice_sg.id
}

output "eice_endpoint_id" {
  description = "ID of the EC2 Instance Connect Endpoint"
  value       = aws_ec2_instance_connect_endpoint.sftp_eice.id
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

# ── Access Commands ───────────────────────────────────────────────────────────

output "retrieve_key_command" {
  description = "Step 1 – Retrieve the SSH private key from Secrets Manager"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.sftp_ssh_private_key.name} --profile CoreProdWorkloadAccount --region ap-south-1 --query SecretString --output text | jq -r '.private_key' > sftp-ubuntu.pem && chmod 400 sftp-ubuntu.pem"
}

output "ssh_via_eice_command" {
  description = "Step 2a – SSH via EC2 Instance Connect Endpoint (no bastion, no public IP needed)"
  value       = "ssh -i sftp-ubuntu.pem -o ProxyCommand='aws ec2-instance-connect open-tunnel --instance-id ${aws_instance.sftp_ubuntu.id} --region ap-south-1 --profile CoreProdWorkloadAccount' ubuntu@${aws_instance.sftp_ubuntu.private_ip}"
}

output "ssm_session_command" {
  description = "Step 2b – Open a shell via SSM Session Manager (no SSH key needed, requires SSM agent running)"
  value       = "aws ssm start-session --target ${aws_instance.sftp_ubuntu.id} --region ap-south-1 --profile CoreProdWorkloadAccount"
}

output "sftp_via_eice_command" {
  description = "SFTP via EC2 Instance Connect Endpoint"
  value       = "sftp -i sftp-ubuntu.pem -o ProxyCommand='aws ec2-instance-connect open-tunnel --instance-id ${aws_instance.sftp_ubuntu.id} --region ap-south-1 --profile CoreProdWorkloadAccount' ubuntu@${aws_instance.sftp_ubuntu.private_ip}"
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

# ── SSM VPC Endpoint Outputs ──────────────────────────────────────────────────

output "ssm_endpoint_id" {
  description = "ID of the SSM VPC interface endpoint"
  value       = aws_vpc_endpoint.ssm.id
}

output "ssmmessages_endpoint_id" {
  description = "ID of the SSM Messages VPC interface endpoint"
  value       = aws_vpc_endpoint.ssmmessages.id
}

output "ec2messages_endpoint_id" {
  description = "ID of the EC2 Messages VPC interface endpoint"
  value       = aws_vpc_endpoint.ec2messages.id
}

# ── Elastic IP Outputs ────────────────────────────────────────────────────────

output "elastic_public_ip" {
  description = "Permanent Elastic IP (public) assigned to the SFTP instance"
  value       = aws_eip.sftp_eip.public_ip
}

output "elastic_ip_id" {
  description = "Allocation ID of the Elastic IP"
  value       = aws_eip.sftp_eip.id
}

output "elastic_ip_association_id" {
  description = "Association ID linking the EIP to the EC2 instance"
  value       = aws_eip_association.sftp_eip_assoc.id
}

output "ssh_via_eip_command" {
  description = "SSH command using the Elastic IP (requires public route to instance)"
  value       = "ssh -i sftp-ubuntu.pem -o StrictHostKeyChecking=no ubuntu@${aws_eip.sftp_eip.public_ip}"
}

# ── EICE Permission Fix ───────────────────────────────────────────────────────

output "eice_policy_arn" {
  description = "ARN of the IAM policy to attach to CLI users/roles needing EICE OpenTunnel access"
  value       = aws_iam_policy.eice_open_tunnel_policy.arn
}

output "attach_eice_policy_command" {
  description = "AWS CLI command to attach the EICE OpenTunnel policy to OrganizationAccountAccessRole"
  value       = "aws iam attach-role-policy --role-name OrganizationAccountAccessRole --policy-arn ${aws_iam_policy.eice_open_tunnel_policy.arn} --region ${var.aws_region} --profile ${var.aws_profile}"
}
