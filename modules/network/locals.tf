# Copyright 2017, 2023 Oracle Corporation and/or affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

locals {

  # first vcn cidr is dmz lb
  # second cidr is internal subnets
  vcn_cidr_dmz = element(data.oci_core_vcn.vcn.cidr_blocks, 0)
  vcn_cidr     = element(data.oci_core_vcn.vcn.cidr_blocks, 1)

  # Check if pub_lb_subnet exceeds available address space, then fallback to local.vcn_cidr

  pub_lb_subnet = can(local.vcn_cidr_dmz) ? local.vcn_cidr_dmz : cidrsubnet(local.vcn_cidr, lookup(var.subnets["pub_lb"], "newbits"), lookup(var.subnets["pub_lb"], "netnum"))

  # subnet cidrs - used by subnets
  bastion_subnet = var.create_bastion ? (can(local.vcn_cidr_dmz) ? local.vcn_cidr_dmz : cidrsubnet(local.vcn_cidr_dmz, lookup(var.subnets["bastion"], "newbits"), lookup(var.subnets["bastion"], "netnum"))) : null

  cp_subnet = cidrsubnet(local.vcn_cidr, lookup(var.subnets["cp"], "newbits", 13), lookup(var.subnets["cp"], "netnum", 1))

  int_lb_subnet = cidrsubnet(local.vcn_cidr, lookup(var.subnets["int_lb"], "newbits"), lookup(var.subnets["int_lb"], "netnum"))

  operator_subnet = var.create_operator ? cidrsubnet(local.vcn_cidr_dmz, lookup(var.subnets["operator"], "newbits"), lookup(var.subnets["operator"], "netnum")) : ""

  workers_subnet = cidrsubnet(local.vcn_cidr, lookup(var.subnets["workers"], "newbits"), lookup(var.subnets["workers"], "netnum"))

  pods_subnet = cidrsubnet(local.vcn_cidr, lookup(var.subnets["pods"], "newbits"), lookup(var.subnets["pods"], "netnum"))

  fss_subnet = cidrsubnet(local.vcn_cidr, lookup(var.subnets["fss"], "newbits"), lookup(var.subnets["fss"], "netnum"))

  anywhere = "0.0.0.0/0"

  # port numbers
  health_check_port = 10256
  node_port_min     = 30000
  node_port_max     = 32767

  ssh_port = 22

  # protocols
  # # special OCI value for all protocols
  all_protocols = "all"

  # # IANA protocol numbers
  icmp_protocol = 1

  tcp_protocol = 6

  udp_protocol = 17

  # oracle services network
  osn = lookup(data.oci_core_services.all_oci_services.services[0], "cidr_block")

  # if waf is enabled, construct a list of WAF cidrs
  # else return an empty list
  waf_cidr_list = var.enable_waf == true ? [
    for waf_subnet in data.oci_waas_edge_subnets.waf_cidr_blocks[0].edge_subnets :
    waf_subnet.cidr
  ] : []

  # Security configuration
  # See https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengnetworkconfig.htm#securitylistconfig
  # if port = -1, allow all ports

  # Security List rules for control plane subnet (Flannel & VCN-Native Pod networking)
  cp_egress_seclist = [
    {
      description      = "Allow Bastion service to communicate to the control plane endpoint. Required for when using OCI Bastion service.",
      destination      = local.cp_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = 6443,
      stateless        = false
    }
  ]

  cp_ingress_seclist = [
    {
      description = "Allow Bastion service to communicate to the control plane endpoint. Required for when using OCI Bastion service.",
      source      = local.cp_subnet,
      source_type = "CIDR_BLOCK",
      protocol    = local.tcp_protocol,
      port        = 6443,
      stateless   = false
    }
  ]

  # Network Security Group egress rules for control plane subnet (Flannel & VCN-Native Pod networking)
  cp_egress = [
    {
      description      = "Allow Kubernetes Control plane to communicate to the control plane subnet. Required for when using OCI Bastion service.",
      destination      = local.cp_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = 6443,
      stateless        = false
    },
    {
      description      = "Allow Kubernetes control plane to communicate with OKE",
      destination      = local.osn,
      destination_type = "SERVICE_CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = -1,
      stateless        = false
    },
    {
      description      = "Allow Kubernetes Control plane to communicate with worker nodes",
      destination      = local.workers_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = 10250,
      stateless        = false
    },
    {
      description      = "Allow ICMP traffic for path discovery to worker nodes",
      destination      = local.workers_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.icmp_protocol,
      port             = -1,
      stateless        = false
    },
  ]

  # Network Security Group ingress rules for control plane subnet (Flannel & VCN-Native Pod networking)
  cp_ingress = concat(var.cni_type == "npn" ? local.cp_ingress_npn : [], [
    {
      description = "Allow worker nodes to control plane API endpoint communication"
      protocol    = local.tcp_protocol,
      port        = 6443,
      source      = local.workers_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow worker nodes to control plane communication"
      protocol    = local.tcp_protocol,
      port        = 12250,
      source      = local.workers_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow ICMP traffic for path discovery from worker nodes"
      protocol    = local.icmp_protocol,
      port        = -1,
      source      = local.workers_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
  ])

  # Network Security Group ingress rules for control plane subnet (Only VCN-Native Pod networking)
  cp_ingress_npn = [
    {
      description = "Allow pods to control plane API endpoint communication"
      protocol    = local.tcp_protocol,
      port        = 6443,
      source      = local.pods_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow pods to control plane communication"
      protocol    = local.tcp_protocol,
      port        = 12250,
      source      = local.pods_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
  ]

  # Network Security Group egress rules for workers subnet (Flannel & VCN-Native Pod networking)
  workers_egress = [
    {
      description      = "Allows communication from (or to) worker nodes.",
      destination      = local.workers_subnet
      destination_type = "CIDR_BLOCK",
      protocol         = local.all_protocols,
      port             = -1,
      stateless        = false
    },
    {
      description      = "Allow ICMP traffic for path discovery",
      destination      = local.anywhere
      destination_type = "CIDR_BLOCK",
      protocol         = local.icmp_protocol,
      port             = -1,
      stateless        = false
    },
    {
      description      = "Allow worker nodes to communicate with OKE",
      destination      = local.osn,
      destination_type = "SERVICE_CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = -1,
      stateless        = false
    },
    {
      description      = "Allow worker nodes to control plane API endpoint communication",
      destination      = local.cp_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = 6443,
      stateless        = false
    },
    {
      description      = "Allow worker nodes to control plane communication",
      destination      = local.cp_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = 12250,
      stateless        = false
    }
  ]

  # Network Security Group ingress rules for workers subnet (Flannel & VCN-Native Pod networking)
  workers_ingress = [
    {
      description = "Allow ingress for all traffic to allow pods to communicate between each other on different worker nodes on the worker subnet",
      protocol    = local.all_protocols,
      port        = -1,
      source      = local.workers_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow control plane to communicate with worker nodes",
      protocol    = local.tcp_protocol,
      port        = 10250,
      source      = local.cp_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow path discovery from worker nodes"
      protocol    = local.icmp_protocol,
      port        = -1,
      //this should be local.worker_subnet?
      source      = local.anywhere,
      source_type = "CIDR_BLOCK",
      stateless   = false
    }
  ]

  # Network Security Group egress rules for pods subnet (VCN-Native Pod networking only)
  pods_egress = [
    {
      description      = "Allow pods to communicate with other pods.",
      destination      = local.pods_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.all_protocols,
      port             = -1,
      stateless        = false
    },
    {
      description      = "Allow ICMP traffic for path discovery",
      destination      = local.osn,
      destination_type = "SERVICE_CIDR_BLOCK",
      protocol         = local.icmp_protocol,
      port             = -1,
      stateless        = false
    },
    {
      description      = "Allow pods to communicate with OCI Services",
      destination      = local.osn,
      destination_type = "SERVICE_CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = -1,
      stateless        = false
    },
    {
      description      = "Allow pods to communicate with Kubernetes API server",
      destination      = local.cp_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = 6443,
      stateless        = false
    }
  ]

  # Network Security Group ingress rules for pods subnet (VCN-Native Pod networking only)
  pods_ingress = [
    {
      description = "Allow Kubernetes control plane to communicate with webhooks served by pods",
      protocol    = local.all_protocols,
      port        = -1,
      source      = local.cp_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow cross-node pod communication when using NodePorts or hostNetwork: true",
      protocol    = local.all_protocols,
      port        = -1,
      source      = local.workers_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow pods to communicate with each other.",
      protocol    = local.all_protocols,
      port        = -1,
      source      = local.pods_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
  ]

  # Network Security Group rules for load balancer subnet
  int_lb_egress = [
    {
      description      = "Allow stateful egress to workers. Required for NodePorts",
      destination      = local.workers_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = "30000-32767",
      stateless        = false
    },
    {
      description      = "Allow ICMP traffic for path discovery to worker nodes",
      destination      = local.workers_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.icmp_protocol,
      port             = -1,
      stateless        = false
    },
    {
      description      = "Allow stateful egress to workers. Required for load balancer http/tcp health checks",
      destination      = local.workers_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = local.health_check_port,
      stateless        = false
    },
  ]

  # Combine supplied allow list and the public load balancer subnet
  internal_lb_allowed_cidrs = var.load_balancers == "both" ? concat(var.internal_lb_allowed_cidrs, tolist([local.pub_lb_subnet])) : var.internal_lb_allowed_cidrs

  # Create a Cartesian product of allowed cidrs and ports
  internal_lb_allowed_cidrs_and_ports = setproduct(local.internal_lb_allowed_cidrs, var.internal_lb_allowed_ports)

  pub_lb_egress = [
    # {
    #   description      = "Allow stateful egress to internal load balancers subnet on port 80",
    #   destination      = local.int_lb_subnet,
    #   destination_type = "CIDR_BLOCK",
    #   protocol         = local.tcp_protocol,
    #   port             = 80
    #   stateless        = false
    # },
    # {
    #   description      = "Allow stateful egress to internal load balancers subnet on port 443",
    #   destination      = local.int_lb_subnet,
    #   destination_type = "CIDR_BLOCK",
    #   protocol         = local.tcp_protocol,
    #   port             = 443
    #   stateless        = false
    # },
    {
      description      = "Allow stateful egress to workers. Required for NodePorts",
      destination      = local.workers_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = "30000-32767",
      stateless        = false
    },
    {
      description      = "Allow ICMP traffic for path discovery to worker nodes",
      destination      = local.workers_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.icmp_protocol,
      port             = -1,
      stateless        = false
    },
  ]

  public_lb_allowed_cidrs           = var.public_lb_allowed_cidrs
  public_lb_allowed_cidrs_and_ports = setproduct(local.public_lb_allowed_cidrs, var.public_lb_allowed_ports)

  # fss instance worker subnet security rules
  fss_inst_ingress = [
    {
      description = "Allow ingress UDP traffic from FSS (Mount Target) subnet to port 111 on OKE worker subnet",
      protocol    = local.udp_protocol,
      port        = 111,
      source      = local.fss_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow ingress TCP traffic from FSS (Mount Target) subnet to port 111 on OKE worker subnet",
      protocol    = local.tcp_protocol,
      port        = 111,
      source      = local.fss_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow ingress TCP traffic from FSS (Mount Target) subnet to port 2048 on OKE worker subnet",
      protocol    = local.tcp_protocol,
      port        = 2048,
      source      = local.fss_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow ingress TCP traffic from FSS (Mount Target) subnet to port 2049 on OKE worker subnet",
      protocol    = local.tcp_protocol,
      port        = 2049,
      source      = local.fss_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
    {
      description = "Allow ingress TCP traffic from FSS (Mount Target) subnet to port 2050 on OKE worker subnet",
      protocol    = local.tcp_protocol,
      port        = 2050,
      source      = local.fss_subnet,
      source_type = "CIDR_BLOCK",
      stateless   = false
    },
  ]

  fss_inst_egress = [
    {
      description      = "Allow egress UDP traffic from OKE worker subnet to port 111 on FSS (Mount Target) subnet",
      destination      = local.fss_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.udp_protocol,
      port             = "111",
      stateless        = "false"
    },
    {
      description      = "Allow egress UDP traffic from OKE worker subnet to port 2048 on FSS (Mount Target) subnet",
      destination      = local.fss_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.udp_protocol,
      port             = "2048",
      stateless        = "false"
    },
    {
      description      = "Allow egress TCP traffic from OKE worker subnet to port 111 on FSS (Mount Target) subnet",
      destination      = local.fss_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = "111",
      stateless        = "false"
    },
    {
      description      = "Allow egress TCP traffic from OKE worker subnet to port 2048 on FSS (Mount Target) subnet",
      destination      = local.fss_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = "2048",
      stateless        = "false"
    },
    {
      description      = "Allow egress TCP traffic from OKE worker subnet to port 2049 on FSS (Mount Target) subnet",
      destination      = local.fss_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = "2049",
      stateless        = "false"
    },
    {
      description      = "Allow egress TCP traffic from OKE worker subnet to port 2050 on FSS (Mount Target) subnet",
      destination      = local.fss_subnet,
      destination_type = "CIDR_BLOCK",
      protocol         = local.tcp_protocol,
      port             = "2050",
      stateless        = "false"
    },
  ]
}
