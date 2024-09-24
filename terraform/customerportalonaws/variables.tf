variable "vpc_id" {
  description = "The ID of the existing VPC"
  type        = string
}

variable "subnet_id" {
  description = "The ID of the existing subnet"
  type        = string
}

variable "organization_id" {
  type = string
}

variable "token_key" {
  type = string
}

variable "token_secret" {
  type = string
}


variable "service_password" {
  type = string
  sensitive   = true
}

variable "confluent_organization_id" {
  type = string
}

variable "confluent_cloud_api_key" {
  type = string
}


variable "confluent_cloud_api_secret" {
  type = string
}

variable "activation_key" {
  description = "Activation key for the Storage Gateway"
  type        = string
}



