terraform {
    required_providers {
        aws = {
            source                  = "hashicorp/aws"
            version                 = "4.36.1"
        }
    }

    # backend "local" {
    #     path = "DONTDELETE/terraform.tfstate"
    # }

    # Comment out until permanent DEV S3 storage determined.
    # No vars allowed in this block. Pain.
    backend "s3" {
        region                      = "us-east-1"  
        bucket                      = "dovetailtroubleshooting"
        key                         = "terraform/terraform.tfstate"
        dynamodb_table              = "graham_tf_lock_state"
        encrypt                     = false
        role_arn                    = "arn:aws:iam::128997144437:role/TowerDevelopmentRole"
    }
}

provider "aws" {
    # shared_credentials_files        = ["~/.aws/credentials"]
    region                          = var.region
    profile                         = "sts" # var.profile
    # assume_role {
    #   role_arn                      = "arn:aws:iam::128997144437:role/TowerDevelopmentRole"
    #   session_name                  = "graham_tf_session"
    # }

    default_tags {
      tags = {
        Managed_by                  = "Terraform"
        Project                     = var.project
        Name                        = "${local.tf_prefix}"
        tag-key                     = "${local.tf_prefix}" 
      }
    }    
}

# Generate unique namespace for this deployment (e.g "modern-sheep")
resource "random_pet" "stackname" {
    length                          = 2
}

locals {
    tf_prefix                       = "tf-${var.project}-${random_pet.stackname.id}"
}

# NOTE: Not using due to reasons in README.md
# module "bootstrap" {
#   source                      = "./modules/bootstrap"
#   name_of_s3_bucket           = "your_globally_unique_bucket_name"
#   dynamo_db_table_name        = "aws-locks"
#   iam_user_name               = "IamUser"
#   ado_iam_role_name           = "IamRole"
#   aws_iam_policy_permits_name = "IamPolicyPermits"
#   aws_iam_policy_assume_name  = "IamPolicyAssume"
# }

resource "tls_private_key" "ec2_ssh_key" {
  algorithm                         = "RSA"
  rsa_bits                          = 4096
}

data "aws_vpc" "main" {
    id = var.vpc_id
}

resource "aws_security_group" "proxy_allow_ssh" {
  name        = "${local.tf_prefix}-proxy"
  description = "Allow SSH inbound traffic to Proxy Server"
  # vpc_id      = data.aws_vpc.main.id
  vpc_id      = var.vpc_id

  ingress {
    description      = "TLS from VPC"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  ingress {
    description      = "TLS from VPC"
    from_port        = 8888
    to_port          = 8888
    protocol         = "tcp"
    cidr_blocks      = [data.aws_vpc.main.cidr_block]
  }

  # ingress {
  #   description      = "TLS from VPC"
  #   from_port        = 443
  #   to_port          = 8888
  #   protocol         = "tcp"
  #   cidr_blocks      = [data.aws_vpc.main.cidr_block]
  # }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}