# Terraform: GCP infra for cs2-storage

This module describes the GCP resources running for the CS2 Portfolio
Manager's storage-service backend. They were created with `gcloud`
first, so to manage them with Terraform you import them (below):

| Resource                              | Description                                     |
|---------------------------------------|-------------------------------------------------|
| `google_compute_address.cs2_storage_ip` | Reserved static external IP (so DNS stays valid) |
| `google_compute_firewall.allow_https`   | Opens tcp:80 + tcp:443 to the public internet   |
| `google_compute_instance.cs2_storage`   | The e2-micro VM running Caddy + the Node.js service |

GCP's default-allow-* firewall rules (SSH, ICMP, internal, RDP) are
created automatically with every GCP network and intentionally not
declared here.

## First-time setup

Requires Terraform >= 1.6 and an authenticated `gcloud` CLI.

```bash
# Auth once if you haven't:
gcloud auth application-default login

cd terraform
terraform init
```

## Plan against existing infra (no-op, for verification)

If the resources already exist in GCP (created via `gcloud` or the
console before this module was written), import them first so
Terraform takes ownership instead of trying to recreate them:

```bash
terraform import -var "project_id=cs2-portfolio" \
  google_compute_address.cs2_storage_ip projects/cs2-portfolio/regions/us-central1/addresses/cs2-storage-ip

terraform import -var "project_id=cs2-portfolio" \
  google_compute_firewall.allow_https projects/cs2-portfolio/global/firewalls/allow-cs2-https

terraform import -var "project_id=cs2-portfolio" \
  google_compute_instance.cs2_storage projects/cs2-portfolio/zones/us-central1-a/instances/cs2-storage
```

After import, `terraform plan` should report no changes. The config
mirrors the live VM (service account and scopes, shielded-VM settings,
two-block firewall rule), and two things are deliberately ignored:

- **Instance metadata**: SSH keys are added by `gcloud compute ssh`.
  Managing metadata here would delete them on apply.
- **Boot image**: the `ubuntu-2204-lts` family keeps moving to newer
  images. Without ignoring it, Terraform would plan to *replace* the VM
  (and lose its Steam session) whenever a new image is published.

Review the plan before any apply. Anything marked "must be replaced"
on the instance means something drifted.

## Apply (provisions new infra in an empty project)

```bash
terraform apply -var "project_id=YOUR_PROJECT_ID"
```

The default values target the GCP Always Free tier:
e2-micro in us-central1, 10 GB standard persistent disk, premium-tier
networking on the static IP.

## Outputs

- `external_ip` — the static IP. Point your DNS A record at this.
- `vm_self_link` — fully qualified resource URL.
- `vm_name` — instance name.
- `ssh_command` — copy-paste `gcloud compute ssh` for the VM.

## What this does NOT manage

- The DuckDNS subdomain (external service)
- The Caddyfile and TLS certs (managed on the VM by Caddy itself)
- The storage-service code (deployed via `.github/workflows/deploy-storage.yml`)
- The Steam refresh token at `storage-service/.refresh_token` (manual one-time setup)

Infra only.
