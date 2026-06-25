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
  description = "Zone within the region (AlloyDB / subnet locality)."
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

variable "alloydb_authorized_cidr" {
  type        = string
  description = "CIDR allowed to reach the AlloyDB public IP for psql (e.g. YOUR.IP/32). Empty disables the public IP entirely."
  default     = ""
}

variable "labels" {
  type    = map(string)
  default = { app = "zucchini-datalake", env = "poc" }
}
