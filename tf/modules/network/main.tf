#
# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

locals {
  tmp_list = [for part in var.partitions :
              "${join("-", slice(split("-", part.zone), 0, 2))}"]
  region_list = distinct(concat(local.tmp_list, [var.region]))
}

resource "google_compute_network" "cluster_network" {
  count = (var.network_name == null && var.shared_vpc_host_project == null) ? 1 : 0

  name                    = "${var.cluster_name}-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "cluster_subnet" {
  count = (var.subnetwork_name == null && var.shared_vpc_host_project == null) ? length(local.region_list) : 0

  name                     = "${var.cluster_name}-${local.region_list[count.index]}"
  network                  = google_compute_network.cluster_network[0].self_link
  region                   = local.region_list[count.index]
  ip_cidr_range            = "10.${count.index}.0.0/16"
  private_ip_google_access = var.private_ip_google_access
}

resource "google_compute_firewall" "cluster_ssh_firewall" {
  count = ((var.disable_login_public_ips &&
            var.disable_controller_public_ips &&
            var.disable_compute_public_ips) ||
           (var.shared_vpc_host_project != null)) ? 0 : 1

  name          = "${var.cluster_name}-allow-ssh"
  network       = google_compute_network.cluster_network[0].name
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "cluster_iap_ssh_firewall" {
  count = (var.disable_login_public_ips &&
           var.disable_controller_public_ips &&
           var.disable_compute_public_ips &&
           var.shared_vpc_host_project == null) ? 1 : 0

  name          = "${var.cluster_name}-allow-iap"
  network       = google_compute_network.cluster_network[0].name
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "cluster_internal_firewall" {
  count = var.shared_vpc_host_project != null ? 0 : length(local.region_list)

  name = "${var.cluster_name}-${local.region_list[count.index]}-allow-internal"

  network       = google_compute_network.cluster_network[0].name
  source_ranges = ["10.${count.index}.0.0/16"]

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
}

resource "google_compute_router" "cluster_router" {
  count = (var.network_name == null &&
           var.shared_vpc_host_project == null) ? length(local.region_list) : 0

  name = "${var.cluster_name}-${local.region_list[count.index]}-router"

  region  = google_compute_subnetwork.cluster_subnet[count.index].region
  network = google_compute_network.cluster_network[0].self_link
}

resource "google_compute_router_nat" "cluster_nat" {
  count = ((var.disable_login_public_ips ||
            var.disable_controller_public_ips ||
            var.disable_compute_public_ips) &&
           var.network_name == null &&
           var.shared_vpc_host_project == null) ? length(local.region_list) : 0

  name = "${var.cluster_name}-${local.region_list[count.index]}-router-nat"

  router                             = google_compute_router.cluster_router[count.index].name
  region                             = google_compute_router.cluster_router[count.index].region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.cluster_subnet[count.index].self_link
    source_ip_ranges_to_nat = ["PRIMARY_IP_RANGE"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
