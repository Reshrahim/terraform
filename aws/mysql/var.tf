variable "context" {
  description = "This variable contains Radius Recipe context."
  type        = any
}

variable "eksClusterName" {
  description = "Name of the EKS cluster. Used to discover VPC, subnets, and security groups."
  type        = string
}
