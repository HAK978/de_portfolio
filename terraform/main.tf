# GCP infrastructure for the cs2-storage VM and its HTTPS edge.
#
# This module describes the resources running in the `cs2-portfolio`
# GCP project (they were created with gcloud first; see README.md for
# importing them):
#   - A reserved static external IP attached to the VM (so the DNS
#     record at harshcs2.duckdns.org never breaks on restart).
#   - A single Compute Engine VM (`cs2-storage`) on the e2-micro free
#     tier, running Ubuntu 22.04 LTS.
#   - A firewall rule opening tcp:80 + tcp:443 for Caddy to terminate
#     TLS and serve the storage-service over HTTPS.
#
# The pre-existing default-allow-ssh, default-allow-internal,
# default-allow-icmp, and default-allow-rdp rules are GCP defaults and
# are intentionally NOT declared here — they're created automatically
# with every new GCP network and shouldn't be tracked as project state.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Look up the latest Ubuntu 22.04 LTS image. Only used when creating a
# new VM: the existing disk was built from an older image in the family,
# so the instance ignores later image changes (see lifecycle below).
data "google_compute_image" "ubuntu_2204" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

data "google_compute_default_service_account" "default" {}

# Static external IP. Free while attached to a running VM (Always Free
# tier). Detaching costs $0.01/hr — release the address if the VM is
# deleted.
resource "google_compute_address" "cs2_storage_ip" {
  name         = "${var.vm_name}-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

# Firewall: allow public ingress on 80 and 443 so Caddy can answer
# HTTP-01 ACME challenges and serve HTTPS. tcp:3456 (the bare Express
# port) is intentionally NOT opened — Caddy proxies to it over loopback,
# and the service only listens on 127.0.0.1 anyway.
resource "google_compute_firewall" "allow_https" {
  name          = var.https_firewall_name
  network       = var.network
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  description   = "HTTP+HTTPS for Caddy reverse proxy on cs2-storage VM"

  # Two blocks, matching how the live rule was created.
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

# The VM itself. e2-micro is part of the GCP Always Free tier in
# us-central1 (and a few other regions); changing zone or machine_type
# breaks that.
resource "google_compute_instance" "cs2_storage" {
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu_2204.self_link
      size  = var.disk_size_gb
      type  = "pd-standard"
    }
  }

  network_interface {
    network = var.network

    # Bind the reserved static IP so it survives stop/start.
    access_config {
      nat_ip       = google_compute_address.cs2_storage_ip.address
      network_tier = "PREMIUM"
    }
  }

  # Matches the live VM: the default compute service account with the
  # default (narrow) access scopes, which keep the VM's metadata-server
  # token away from Firestore and IAM even though the account has
  # project roles that Cloud Functions use.
  service_account {
    email = data.google_compute_default_service_account.default.email
    scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
    ]
  }

  shielded_instance_config {
    enable_secure_boot          = false
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # Stop before destroy so a `terraform destroy` doesn't fail on a
  # running instance.
  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [
      # SSH keys are managed by `gcloud compute ssh` (instance metadata).
      # Without this, an apply would delete them and lock out both you
      # and the deploy workflow.
      metadata,
      # The family resolves to newer images over time; a changed image
      # would otherwise force replacing the VM (and its Steam session).
      boot_disk[0].initialize_params[0].image,
    ]
  }
}
