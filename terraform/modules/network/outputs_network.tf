output "vpc_id" {
  value       = aws_vpc.this.id
  description = "VPC ID"
}

output "vpc_cidr" {
  value       = aws_vpc.this.cidr_block
  description = "VPC CIDR block"
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "Public subnet IDs (reserved; unused in private-backend design)"
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "Private subnet IDs (EKS nodes/pods)"
}

output "isolated_subnet_ids" {
  value       = aws_subnet.isolated[*].id
  description = "Isolated subnet IDs (RDS)"
}

output "availability_zones" {
  value       = local.azs
  description = "AZs in use"
}

output "nat_enabled" {
  value       = var.enable_nat
  description = "Whether NAT egress is currently enabled"
}

output "private_subnet_cidrs" {
  value       = aws_subnet.private[*].cidr_block
  description = "Private subnet CIDR blocks"
}
