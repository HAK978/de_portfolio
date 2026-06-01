# GCP infrastructure for the cs2-storage VM and its HTTPS edge.
#
# This module declares the resources currently running in the
# `cs2-portfolio` GCP project:
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

# Look up the latest Ubuntu 22.04 LTS image so the VM stays on patches
# without pinning to a specific image release.
data "google_compute_image" "ubuntu_2204" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

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
# port) is intentionally NOT opened — Caddy proxies to it over loopback.
resource "google_compute_firewall" "allow_https" {
  name        = "allow-${var.vm_name}-https"
  network     = var.network
  direction   = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  description = "HTTP+HTTPS for Caddy reverse proxy on cs2-storage VM"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
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

  # Stop before destroy so a `terraform destroy` doesn't fail on a
  # running instance.
  allow_stopping_for_update = true
}
