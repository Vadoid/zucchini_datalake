locals {
  # Use the created project's id when create_project, else the provided id as-is.
  project_id = var.create_project ? google_project.this[0].project_id : var.project_id

  apis = [
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "alloydb.googleapis.com",
    "datastream.googleapis.com",
    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "storage.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "vpcaccess.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
  ]
}

resource "google_project" "this" {
  count           = var.create_project ? 1 : 0
  name            = var.project_id
  project_id      = var.project_id
  billing_account = var.billing_account
  org_id          = var.org_id != "" ? var.org_id : null
  folder_id       = var.folder_id != "" ? var.folder_id : null
  labels          = var.labels

  deletion_policy = "DELETE"
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  project                    = local.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false

  depends_on = [google_project.this]
}

# Short suffix so globally-unique names (GCS bucket) don't collide.
resource "random_id" "suffix" {
  byte_length = 3
}
