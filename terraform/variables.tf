variable "project_id" {
  type        = string
  description = "Target GCP project ID. Created by Terraform when create_project = true."
}

variable "create_project" {
  type        = string
  description = "If true, Terraform creates the project. Requires billing_account and one of org_id/folder_id."
  default     = false
}

variable "billing_account" {
  type        = string
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX). Required when create_project = true."
  default     = ""
}

variable "org_id" {
  type        = string
  description = "Organization ID to create the project under. Mutually exclusive with folder_id."
  default     = ""
}

variable "folder_id" {
  type        = string
  description = "Folder ID to create the project under. Mutually exclusive with org_id."
  default     = ""
}

variable "region" {
  type        = string
  description = "Single region shared by AlloyDB, GCS, BigQuery datasets and Datastream (Iceberg co-location requirement)."
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "Zone for the Datastream reverse-proxy VM."
  default     = "us-central1-a"
}

variable "alloydb_password" {
  type        = string
  description = "Password for the AlloyDB postgres user and the datastream replication user."
  sensitive   = true
}

variable "vpc_name" {
  type    = string
  default = "datalake-vpc"
}

variable "psa_range_name" {
  type        = string
  description = "Name for the Private Services Access allocated range (AlloyDB private IP)."
  default     = "datalake-psa-range"
}

variable "datastream_cidr" {
  type        = string
  description = "/29 CIDR for the Datastream private connectivity peering. Must not overlap the VPC or PSA range."
  default     = "10.81.0.0/29"
}

variable "labels" {
  type    = map(string)
  default = { app = "zucchini-datalake", env = "poc" }
}
