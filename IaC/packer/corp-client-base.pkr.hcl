# Builds a Multipass Ubuntu 24.04 VM with all corp-client packages pre-installed.
#
# Baked in (no runtime variables needed):
#   - realmd, sssd, sssd-tools, adcli, krb5-user (domain join toolchain)
#   - xfce4, tigervnc-standalone-server, dbus-x11 (desktop + VNC)
#   - kubectl, helm, flux, vault, argocd, k9s, yq, jq (k8s toolchain)
#   - Firefox (Mozilla PPA), Sublime Text
#
# NOT baked in (requires runtime values — handled by cloud-init at apply time):
#   - DNS configuration (needs Samba IP)
#   - Domain join (needs domain name, admin password)
#   - VNC password setup
#   - /etc/hosts entries (needs gateway IP)
#
# Artifact: ~/.lab-cache/images/corp-client-base.tar.gz
# Saves ~15-20 minutes on first provision vs. installing everything fresh.
#
# Usage:    packer build packer/corp-client-base.pkr.hcl
#           (or let packer/build.sh manage this automatically)

variable "vm_name" {
  type    = string
  default = "packer-corp-client-base"
}

variable "output_dir" {
  type    = string
  default = ""
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  type    = string
  default = "3G"
}

variable "disk" {
  type    = string
  default = "20G"
}

source "null" "corp_client_base" {
  communicator = "none"
}

build {
  name    = "corp-client-base"
  sources = ["source.null.corp_client_base"]

  provisioner "shell-local" {
    environment_vars = [
      "VM_NAME=${var.vm_name}",
      "CPUS=${var.cpus}",
      "MEMORY=${var.memory}",
      "DISK=${var.disk}",
    ]
    script = "${path.root}/scripts/provision-corp-client-base.sh"
  }

  post-processor "shell-local" {
    environment_vars = [
      "VM_NAME=${var.vm_name}",
      "OUTPUT_DIR=${var.output_dir}",
      "IMAGE_NAME=corp-client-base",
    ]
    script = "${path.root}/scripts/export-image.sh"
  }
}
