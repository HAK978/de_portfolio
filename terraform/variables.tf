variable "project_id" {
  description = "GCP project ID hosting the cs2-storage VM."
  type        = string
}

variable "region" {
  description = "GCP region. Must be one of the Always Free tier regions if you want the e2-micro to stay free (us-central1, us-east1, us-west1)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone inside the region."
  type        = string
  default     = "us-central1-a"
}

variable "vm_name" {
  description = "Name for the Compute Engine instance and the prefix used for its derived resources (static IP, firewall rule)."
  type        = string
  default     = "cs2-storage"
}

variable "machine_type" {
  description = "Compute Engine machine type. e2-micro is the Always Free tier instance."
  type        = string
  default     = "e2-micro"
}

variable "disk_size_gb" {
  description = "Boot disk size in GB. Free tier covers up to 30 GB of standard persistent disk."
  type        = number
  default     = 10
}

variable "network" {
  description = "VPC network the VM and firewall rule attach to."
  type        = string
  default     = "default"
}
