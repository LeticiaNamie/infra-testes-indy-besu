variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
  default     = "besu-dev-node"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

resource "aws_key_pair" "besu" {
  key_name   = "besu-key"
  public_key = file("~/.ssh/besu-key.pub")
}

variable "ami_owner" {
  description = "Ubuntu AMI owner ID"
  type        = string
  default     = "099720109477"
}
