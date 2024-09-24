terraform {
  required_version = ">= 1.3.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    clickhouse = {
     source = "ClickHouse/clickhouse"
     version = "0.0.2"
   }
   confluent = {
      source  = "confluentinc/confluent"
      version = "1.76.0"
    }
  }
}