# Builds a Multipass Ubuntu 24.04 VM with all samba-ad packages pre-installed.
#
# The domain provisioning (samba-tool domain provision, user creation) still
# runs at Terraform apply time via cloud-init because it requires runtime
# variables (domain name, admin password, DC IP). This image only pre-bakes
# the package installation phase, saving ~3-5 minutes per provision.
#
# Artifact: ~/.lab-cache/images/samba-base.tar.gz
# Usage:    packer build packer/samba-base.pkr.hcl
#           (or let packer/build.sh manage this automatically)

variable "vm_name" {
  type    = string
  default = "packer-samba-base"
}

variable "output_dir" {
  type    = string
  default = ""
  # Default resolved at runtime in shell-local to honour ~ expansion
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  type    = string
  default = "2G"
}

variable "disk" {
  type    = string
  default = "10G"
}

source "null" "samba_base" {
  communicator = "none"
}

build {
  name    = "samba-base"
  sources = ["source.null.samba_base"]

  # Launch a clean Ubuntu 24.04 VM and install all samba-ad packages.
  provisioner "shell-local" {
    environment_vars = [
      "VM_NAME=${var.vm_name}",
      "CPUS=${var.cpus}",
      "MEMORY=${var.memory}",
      "DISK=${var.disk}",
    ]
    script = "${path.root}/scripts/provision-samba-base.sh"
  }

  # Export the stopped VM to ~/.lab-cache/images/ and clean up the build instance.
  post-processor "shell-local" {
    environment_vars = [
      "VM_NAME=${var.vm_name}",
      "OUTPUT_DIR=${var.output_dir}",
      "IMAGE_NAME=samba-base",
    ]
    script = "${path.root}/scripts/export-image.sh"
  }
}
