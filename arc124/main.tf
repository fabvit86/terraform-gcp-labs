terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.51.0"
    }
  }
}

locals {
  network_lb_tag = "network-lb-tag"
  http_lb_tag    = "allow-health-check"
  image          = "debian-cloud/debian-11"
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "PROJECT_ID"
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP Zone"
  type        = string
  default     = "us-central1-c"
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# VM 1
resource "google_compute_instance" "vm_instance_1" {
  name         = "web1"
  machine_type = "e2-small"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = local.image
    }
  }

  network_interface {
    network = "default"
    access_config {
      network_tier = "PREMIUM"
    }
  }

  tags                    = [local.network_lb_tag]
  metadata_startup_script = file("startup_script_1.txt")
}

# VM 2
resource "google_compute_instance" "vm_instance_2" {
  name         = "web2"
  machine_type = "e2-small"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = local.image
    }
  }

  network_interface {
    network = "default"
    access_config {
      network_tier = "PREMIUM"
    }
  }

  tags                    = [local.network_lb_tag]
  metadata_startup_script = file("startup_script_2.txt")
}

# VM 3
resource "google_compute_instance" "vm_instance_3" {
  name         = "web3"
  machine_type = "e2-small"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = local.image
    }
  }

  network_interface {
    network = "default"
    access_config {
      network_tier = "PREMIUM"
    }
  }

  tags                    = [local.network_lb_tag]
  metadata_startup_script = file("startup_script_3.txt")
}

# network lb firewall rule
resource "google_compute_firewall" "allow_http_fw_rule" {
  name    = "www-firewall-network-lb"
  network = "default"
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  direction     = "INGRESS"
  priority      = "1000"
  target_tags   = [local.network_lb_tag]
  source_ranges = ["0.0.0.0/0"]
}

# HTTP health check (legacy, for target pool-based network lb)
resource "google_compute_http_health_check" "http_hc" {
  name = "basic-check"
  port = 80
}

# static external IP address
resource "google_compute_address" "network-lb-ip-1" {
  name   = "network-lb-ip-1"
  region = var.region
}

# target pool
resource "google_compute_target_pool" "www-pool" {
  name          = "www-pool"
  region        = var.region
  health_checks = [google_compute_http_health_check.http_hc.id]

  instances = [
    format("%s/web1", var.zone),
    format("%s/web2", var.zone),
    format("%s/web3", var.zone),
  ]
}

# HTTP forwarding rule
resource "google_compute_forwarding_rule" "www-rule" {
  name       = "www-rule"
  region     = var.region
  port_range = "80"
  ip_address = google_compute_address.network-lb-ip-1.id
  target     = google_compute_target_pool.www-pool.id
}

# VM template for HTTP lb backend service
resource "google_compute_instance_template" "lb-backend-template" {
  name         = "lb-backend-template"
  machine_type = "e2-medium"
  region       = var.region

  disk {
    source_image = local.image
  }

  network_interface {
    network = "default"
    access_config {
      network_tier = "PREMIUM"
    }
  }

  tags                    = [local.http_lb_tag]
  metadata_startup_script = file("startup_script_http_lb.txt")
}

# MIG for HTTP lb backend
resource "google_compute_instance_group_manager" "lb-backend-group" {
  name               = "lb-backend-group"
  base_instance_name = "lb-backend"
  zone               = var.zone
  target_size        = 2
  named_port {
    name = "http"
    port = "80"
  }
  version {
    instance_template = google_compute_instance_template.lb-backend-template.id
  }
}

# firewall rule for health check 
resource "google_compute_firewall" "fw-allow-health-check" {
  name    = "fw-allow-health-check"
  network = "default"
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  direction     = "INGRESS"
  priority      = "1000"
  target_tags   = [local.http_lb_tag]
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

# static external IP address for HTTP lb
resource "google_compute_global_address" "lb-ipv4-1" {
  name = "lb-ipv4-1"
}

# health check for HTTP load balancer backend service
resource "google_compute_health_check" "http-basic-check" {
  name = "http-basic-check"
  http_health_check {
    port = 80
  }
}

# HTTP load balancer backend service
resource "google_compute_backend_service" "web-backend-service" {
  name          = "web-backend-service"
  protocol      = "HTTP"
  health_checks = [google_compute_health_check.http-basic-check.id]
  port_name     = "http"
  backend {
    group = google_compute_instance_group_manager.lb-backend-group.instance_group
  }
}

# URL maps that map HTTP request URLs to the HTTP lb backend service
resource "google_compute_url_map" "web-map-http" {
  name            = "web-map-http"
  default_service = google_compute_backend_service.web-backend-service.id
}

# target HTTP proxy that points to the URL map
resource "google_compute_target_http_proxy" "http-lb-proxy" {
  name    = "http-lb-proxy"
  url_map = google_compute_url_map.web-map-http.id
}

# forwarding rule for the HTTP proxy
resource "google_compute_global_forwarding_rule" "http-proxy-rule" {
  name       = "http-proxy-rule"
  port_range = "80"
  ip_address = google_compute_global_address.lb-ipv4-1.id
  target     = google_compute_target_http_proxy.http-lb-proxy.id
}
