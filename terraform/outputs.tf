output "external_ip" {
  description = "Static external IP of the cs2-storage VM. Point your DNS A record at this."
  value       = google_compute_address.cs2_storage_ip.address
}

output "vm_self_link" {
  description = "Fully qualified resource URL for the cs2-storage instance."
  value       = google_compute_instance.cs2_storage.self_link
}

output "vm_name" {
  description = "Name of the Compute Engine instance."
  value       = google_compute_instance.cs2_storage.name
}

output "ssh_command" {
  description = "Convenience: gcloud SSH command to reach the VM."
  value       = "gcloud compute ssh ${google_compute_instance.cs2_storage.name} --zone=${google_compute_instance.cs2_storage.zone}"
}
