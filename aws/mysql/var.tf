variable "context" {
  description = "This variable contains Radius Recipe context."
  type        = any
}

variable "subnetIds" {
  description = "List of subnet IDs for the RDS subnet group. Should be subnets in the EKS cluster's VPC."
  type        = list(string)
}

variable "vpcId" {
  description = "VPC ID where the EKS cluster is running."
  type        = string
}

variable "securityGroupId" {
  description = "Security group ID that allows access from the EKS cluster nodes."
  type        = string
}
