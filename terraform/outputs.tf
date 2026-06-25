output "project_id" {
  value = local.project_id
}

output "region" {
  value = var.region
}

output "zone" {
  value = var.zone
}

output "alloydb_public_ip" {
  value       = try(google_alloydb_instance.primary.public_ip_address, "")
  description = "AlloyDB public IP (psql from your laptop). Empty when alloydb_authorized_cidr unset."
}

output "stream_id" {
  value = try(google_datastream_stream.alloydb_to_iceberg[0].stream_id, "alloydb-to-iceberg")
}

output "alloydb_ip" {
  value       = google_alloydb_instance.primary.ip_address
  description = "AlloyDB primary private IP."
}

output "iceberg_bucket" {
  value = google_storage_bucket.iceberg.name
}

output "biglake_connection" {
  value = google_bigquery_connection.biglake.name
}

output "function_uri" {
  value = google_cloudfunctions2_function.streamer.service_config[0].uri
}

output "scheduler_job" {
  value       = google_cloud_scheduler_job.tick.name
  description = "Resume to start streaming, pause to stop."
}

output "datasets" {
  value = {
    alloydb_iceberg  = google_bigquery_dataset.alloydb_iceberg.dataset_id
    bigquery_iceberg = google_bigquery_dataset.bigquery_iceberg.dataset_id
    common_layer     = google_bigquery_dataset.common_layer.dataset_id
  }
}
