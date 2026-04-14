variable "context" {
  description = "This variable contains Radius Recipe context."
  type        = any
}

variable "eksClusterName" {
  description = "Name of the EKS cluster. Used to discover VPC, subnets, and security groups."
  type        = string
}

variable "subnetGroupName" {
  description = "Name of an existing DB subnet group. If not provided, one is created using EKS cluster subnets."
  type        = string
  default     = ""
}

variable "vpcSecurityGroupIds" {
  description = "List of VPC security group IDs for the RDS instance. If not provided, the EKS cluster security group is used."
  type        = list(string)
  default     = []
}
