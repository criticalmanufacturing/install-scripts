provider "aws" {
  region = local.region
}
provider clickhouse {
  organization_id = var.organization_id
  token_key     = var.token_key
  token_secret  = var.token_secret
  environment = "production"
}

provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key    # optionally use CONFLUENT_CLOUD_API_KEY env var
  cloud_api_secret = var.confluent_cloud_api_secret # optionally use CONFLUENT_CLOUD_API_SECRET env var
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

locals {
#   name            = "ex-${replace(basename(path.cwd), "_", "-")}"
  name = "customerportal-test-nfalmeida"
  cluster_version = "1.30"
  region          = "eu-central-1"

  vpc_cidr = "10.10.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

}


################################################################################
# Supporting Resources
################################################################################



module "vpc" {
  count = 1
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr
  map_public_ip_on_launch = true

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_ipv6            = false
  create_egress_only_igw = false  # Make sure this is false as you need an internet gateway

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

#   tags = local.tags
}


# Determine VPC to use
locals {
  vpc =  module.vpc[0]
}

resource "aws_internet_gateway" "main" {
  vpc_id = local.vpc.vpc_id
  tags = {
    Name = "main-internet-gateway"
  }
}

resource "aws_route_table" "public" {
  vpc_id = local.vpc.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public" {
  count      = length(local.vpc.public_subnets)
  subnet_id  = local.vpc.public_subnets[count.index]
  route_table_id = aws_route_table.public.id
}


module "ebs_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 2.1"

  description = "Customer managed key to encrypt EKS managed node group volumes"

  # Policy
  key_administrators = [
    data.aws_caller_identity.current.arn
  ]

  key_service_roles_for_autoscaling = [
    # required for the ASG to manage encrypted volumes for nodes
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
    # required for the cluster / persistentvolume-controller to create encrypted PVCs
    module.eks.cluster_iam_role_arn,
  ]

  # Aliases
  aliases = ["eks/${local.name}/ebs"]

#   tags = local.tags
}

module "key_pair" {
  source  = "terraform-aws-modules/key-pair/aws"
  version = "~> 2.0"

  key_name_prefix    = local.name
  create_private_key = true

#   tags = local.tags
}

resource "aws_iam_policy" "node_additional" {
  name        = "${local.name}-additional"
  description = "Example usage of node additional policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:Describe*",
        ]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })

#   tags = local.tags
}


resource "aws_iam_role" "this" {
  for_each = toset(["single", "multiple"])

  name = "ex-${each.key}"

  # Just using for this example
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = "Example"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

#   tags = local.tags
}


################################################################################
# EKS Module
################################################################################

module "eks" {
  source = "terraform-aws-modules/eks/aws"

  cluster_name                   = local.name
  cluster_version                = local.cluster_version
  cluster_endpoint_public_access = true

  # IPV6
  cluster_ip_family          = "ipv6"
  create_cni_ipv6_iam_policy = true

  enable_cluster_creator_admin_permissions = true

  # Enable EFA support by adding necessary security group rules
  # to the shared node security group
  enable_efa_support = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
    }
  }

  vpc_id                   = local.vpc.vpc_id
  subnet_ids               = local.vpc.private_subnets
  control_plane_subnet_ids = local.vpc.intra_subnets

  eks_managed_node_groups = {

    customportal-nodes = {

      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m3.large"]

      min_size     = 1
      max_size     = 5
      desired_size = 3
    }
  }

  access_entries = {
    # One access entry with a policy associated
    ex-single = {
      kubernetes_groups = []
      principal_arn     = aws_iam_role.this["single"].arn

      policy_associations = {
        single = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            namespaces = ["default"]
            type       = "namespace"
          }
        }
      }
    }

    # Example of adding multiple policies to a single access entry
    ex-multiple = {
      kubernetes_groups = []
      principal_arn     = aws_iam_role.this["multiple"].arn

      policy_associations = {
        ex-one = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = {
            namespaces = ["default"]
            type       = "namespace"
          }
        }
        ex-two = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

#   tags = local.tags
}



################################################################################
# File Share + Storage Gateway + S3
################################################################################

module "s3_bucket" {
  source = "./storage/s3"
}

module "iam" {
  source = "./storage/iam-role"

  # Pass the S3 bucket ARN from the s3 module
  bucket_arn = module.s3_bucket.bucket_arn

}


module "storage_gateway" {
  source = "./storage/storage-gateway"
  vpc = local.vpc
  activation_key = var.activation_key
  gateway_role_arn = module.iam.gateway_role_arn
  bucket_arn = module.s3_bucket.bucket_arn
}




################################################################################
# Elastic IPs
################################################################################

resource "aws_eip" "eip1" {
  count = 1
  vpc = true
  tags = {
    Name = "ElasticIP1"
  }
}

resource "aws_eip" "eip2" {
  count = 1
  vpc = true
  tags = {
    Name = "ElasticIP2"
  }
}

resource "aws_eip" "eip3" {
  count = 1
  vpc = true
  tags = {
    Name = "ElasticIP3"
  }
}

################################################################################
# S3 bucket
################################################################################


resource "aws_s3_bucket" "s3_bucket" {
  bucket = "rn-dev-bucket"

  tags = {
    Name        = "rn-dev-bucket"
    Environment = "Dev"
  }
}


################################################################################
# RabbitMQ
################################################################################


resource "aws_mq_configuration" "rabbitmq_config" {
  description    = "rabbitmq-config"
  name           = "rabbitmq_config"
  engine_type    = "RabbitMQ"
  engine_version = "3.11.20"

  data = <<DATA
# Default RabbitMQ delivery acknowledgement timeout is 30 minutes in milliseconds
consumer_timeout = 1800000
DATA
}



resource "aws_mq_broker" "rabbitmq_broker" {
  broker_name        = "rabbitmq-broker"
  engine_type        = "RabbitMQ"
  engine_version     = "3.11.20"
  host_instance_type = "mq.t3.micro"

  auto_minor_version_upgrade = true
  publicly_accessible        = false

  configuration {
    id       = aws_mq_configuration.rabbitmq_config.id
    revision = aws_mq_configuration.rabbitmq_config.latest_revision
  }

  subnet_ids      = [local.vpc.public_subnets[0]]
  security_groups = ["sg-0515f495790ff2bc0"] # default one

  user {
    username = "admin"
    password = "qaz123WSXqaz123WSX"
  }

  logs {
    general = true
  }

  tags = {
    Environment = "production"
    Application = "RabbitMQ"
  }
}


################################################################################
# Clikhouse
################################################################################


resource "clickhouse_service" "clickhouse_service" {
  name          = "rita-clickhouse-service"
  cloud_provider = "aws"
  region        = local.region
  tier          = "development"
  idle_scaling   = true
  password  = var.service_password
  ip_access = [
    {
        source      = "0.0.0.0/0"
        description = "Anywhere"
    }
  ]
}


################################################################################
# Kafka
################################################################################

resource "confluent_environment" "development" {
  display_name = "Kafka"

  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_kafka_cluster" "basic" {
  display_name = "basic_kafka_cluster"
  availability = "SINGLE_ZONE"
  cloud        = "AWS"
  region       = local.region
  basic {}

  environment {
    id = confluent_environment.development.id
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_service_account" "app-manager" {
  display_name = "app-manager"
  description  = "Service account to manage Kafka cluster"
}
