variable "ad_domain" {
  description = "Active Directory domain name. Azure equivalent: the primary domain of an Entra ID tenant."
  type        = string
  default     = "corp.internal"
}

variable "ad_domain_netbios" {
  description = "NetBIOS (short) name for the domain — used by older Windows clients and Samba. Azure equivalent: the tenant short name."
  type        = string
  default     = "CORP"
}

variable "ad_admin_password" {
  description = <<-DESC
    Password for the built-in Administrator account provisioned during samba-tool domain provision.
    Must meet Samba complexity requirements: 8+ chars, upper, lower, digit, special.
    Safe to commit — lab only, not a real credential.
  DESC
  type        = string
  default     = "AksLab!AdDev1"
  sensitive   = true
}

variable "ad_test_user1_pass" {
  description = "Password for testuser1. Lab credential only."
  type        = string
  default     = "AksLab!User1"
  sensitive   = true
}

variable "ad_test_user2_pass" {
  description = "Password for testuser2. Lab credential only."
  type        = string
  default     = "AksLab!User2"
  sensitive   = true
}

variable "samba_vm_cpus" {
  description = "CPU count for the samba-ad Multipass VM."
  type        = number
  default     = 2
  validation {
    condition     = var.samba_vm_cpus >= 1
    error_message = "samba_vm_cpus must be at least 1."
  }
}

variable "samba_vm_memory" {
  description = "Memory for the samba-ad Multipass VM (Multipass size format: 2G, 1500M, etc.)."
  type        = string
  default     = "2G"
  validation {
    condition     = can(regex("^[0-9]+(M|G)$", var.samba_vm_memory))
    error_message = "samba_vm_memory must be a Multipass size like 2G, 1500M."
  }
}

variable "samba_vm_disk" {
  description = "Disk size for the samba-ad Multipass VM."
  type        = string
  default     = "20G"
  validation {
    condition     = can(regex("^[0-9]+(M|G)$", var.samba_vm_disk))
    error_message = "samba_vm_disk must be a Multipass size like 20G, 5000M."
  }
}

variable "client_vm_cpus" {
  description = "CPU count for the corp-client Multipass VM."
  type        = number
  default     = 2
  validation {
    condition     = var.client_vm_cpus >= 1
    error_message = "client_vm_cpus must be at least 1."
  }
}

variable "client_vm_memory" {
  description = "Memory for the corp-client Multipass VM. XFCE + VNC needs at least 2G."
  type        = string
  default     = "2G"
  validation {
    condition     = can(regex("^[0-9]+(M|G)$", var.client_vm_memory))
    error_message = "client_vm_memory must be a Multipass size like 2G, 1500M."
  }
}

variable "client_vm_disk" {
  description = "Disk size for the corp-client Multipass VM."
  type        = string
  default     = "10G"
  validation {
    condition     = can(regex("^[0-9]+(M|G)$", var.client_vm_disk))
    error_message = "client_vm_disk must be a Multipass size like 10G, 5000M."
  }
}

variable "vnc_password" {
  description = "VNC password for the corp-client desktop (max 8 chars). Used with macOS Screen Sharing."
  type        = string
  default     = "AksLab1!"
  sensitive   = true
}

variable "samba_vm_static_ip" {
  description = "Static IP for samba-ad VM on the bridged interface (172.16.2.0/24 subnet). Leave empty to use DHCP."
  type        = string
  default     = "172.16.2.10"
}

variable "corp_client_static_ip" {
  description = "Static IP for corp-client VM on the bridged interface (172.16.2.0/24 subnet). Leave empty to use DHCP."
  type        = string
  default     = "172.16.2.11"
}

variable "vm_subnet_gateway" {
  description = "Default gateway for the 172.16.2.0/24 VM subnet."
  type        = string
  default     = "172.16.0.1"
}
