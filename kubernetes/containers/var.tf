
variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
  default     = null
}

variable "eksClusterName" {
  description = "The EKS cluster name, used for IRSA setup with cloud secrets."
  type        = string
  default     = ""
}
