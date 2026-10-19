module "vpc" {
  source = "./vpc"

  name                 = var.name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = var.tags
}

locals {
  instances = {
    bastion-host = {
      role          = "bastion"
      subnet_id     = module.vpc.public_subnet_ids["az1"]
      instance_type = var.bastion_instance_type
    }
    control-plane1 = {
      role          = "control-plane"
      subnet_id     = module.vpc.private_subnet_ids["az1"]
      instance_type = var.control_plane_instance_type
    }
    control-plane2 = {
      role          = "control-plane"
      subnet_id     = module.vpc.private_subnet_ids["az2"]
      instance_type = var.control_plane_instance_type
    }
    control-plane3 = {
      role          = "control-plane"
      subnet_id     = module.vpc.private_subnet_ids["az1"]
      instance_type = var.control_plane_instance_type
    }
    worker-node1 = {
      role          = "worker"
      subnet_id     = module.vpc.private_subnet_ids["az1"]
      instance_type = var.worker_instance_type
    }
    worker-node2 = {
      role          = "worker"
      subnet_id     = module.vpc.private_subnet_ids["az2"]
      instance_type = var.worker_instance_type
    }
  }
}

module "ec2" {
  source = "./ec2"

  name              = var.name
  vpc_id            = module.vpc.vpc_id
  instances         = local.instances
  ssh_key_name      = var.ssh_key_name
  ssh_ingress_cidrs = var.ssh_ingress_cidrs
  tags              = var.tags
}
