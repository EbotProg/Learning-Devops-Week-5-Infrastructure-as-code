variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "bastion_allowed_ip" {
  type        = string
  description = "Your own public IP (no /32 suffix — that's added automatically). Find it with: curl -s ifconfig.me"
}

variable "key_name" {
  type        = string
  description = "Name of an EXISTING EC2 key pair in this region/account"
  default     = "my-free-key-for-devops-training-server"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "bucket_name" {
  type        = string
  description = "Must be globally unique across ALL of AWS — change if apply fails on this"
  default     = "ebotprog-week5-milestone-bucket"
}
