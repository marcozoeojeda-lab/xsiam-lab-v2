### GENERAL
region      = "us-east-2"        # TODO: update here
name_prefix = "davila-xsiam-lab" # TODO: update here

global_tags = {
  ManagedBy   = "terraform"
  Application = "XSIAM Lab"
  Owner       = "David Avila"
}

ssh_key_name = "xsiam-lab-v2"

### VPC

cidr           = "10.10.0.0/16"
mgt_public_ips = ["186.31.0.249/32"]