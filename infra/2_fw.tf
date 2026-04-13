locals {
  vmseries_instances = flatten([for kv, vv in local.vmseries : [for ki, vi in vv.instances : { group = kv, instance = ki, az = vi.az, common = vv }]])
}

### BOOTSTRAP PACKAGE
module "bootstrap" {
  source = "./modules/bootstrap"

  for_each = { for vmseries in local.vmseries_instances : "${vmseries.group}-${vmseries.instance}" => vmseries }

  iam_role_name             = "${var.name_prefix}vmseries${each.value.instance}"
  iam_instance_profile_name = "${var.name_prefix}vmseries_instance_profile${each.value.instance}"

  prefix      = var.name_prefix
  global_tags = var.global_tags

  bootstrap_options     = merge({ for k, v in each.value.common.bootstrap_options : k => v if v != null }, { hostname = "${var.name_prefix}${each.key}" })
  source_root_directory = "files"
  authcodes             = var.authcodes
}

### VM-Series INSTANCES

module "vmseries" {
  source = "./modules/vmseries"

  for_each = { for vmseries in local.vmseries_instances : "${vmseries.group}-${vmseries.instance}" => vmseries }

  name              = "${var.name_prefix}-${each.key}"
  vmseries_version  = each.value.common.panos_version
  ebs_kms_key_alias = each.value.common.ebs_kms_id

  interfaces = {
    for k, v in each.value.common.interfaces : k => {
      device_index       = v.device_index
      private_ips        = [v.private_ip[each.value.instance]]
      security_group_ids = try([module.vpc[each.value.common.vpc].security_group_ids[v.security_group]], [])
      source_dest_check  = try(v.source_dest_check, false)
      subnet_id          = module.subnet_sets["${v.vpc}-${v.subnet_group}"].subnets[each.value.az].id
      create_public_ip   = try(v.create_public_ip, false)
      eip_allocation_id  = try(v.eip_allocation_id[each.value.instance], null)
      ipv6_address_count = try(v.ipv6_address_count, null)
    }
  }

  bootstrap_options = join(";", compact(concat(
    ["vmseries-bootstrap-aws-s3bucket=${module.bootstrap[each.key].bucket_name}"],
    ["mgmt-interface-swap=${each.value.common.bootstrap_options["mgmt-interface-swap"]}"],
  )))

  iam_instance_profile = module.bootstrap[each.key].instance_profile_name
  ssh_key_name         = var.ssh_key_name
  tags                 = var.global_tags
}

### IAM ROLES AND POLICIES ###

data "aws_caller_identity" "this" {}

data "aws_partition" "this" {}

resource "aws_iam_role_policy" "this" {
  for_each = { for vmseries in local.vmseries_instances : "${vmseries.group}-${vmseries.instance}" => vmseries }
  role     = module.bootstrap[each.key].iam_role_name
  policy   = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "cloudwatch:PutMetricData",
        "cloudwatch:GetMetricData",
        "cloudwatch:ListMetrics"
      ],
      "Resource": [
        "*"
      ],
      "Effect": "Allow"
    },
    {
      "Action": [
        "cloudwatch:PutMetricAlarm",
        "cloudwatch:DescribeAlarms"
      ],
      "Resource": [
        "arn:${data.aws_partition.this.partition}:cloudwatch:${var.region}:${data.aws_caller_identity.this.account_id}:alarm:*"
      ],
      "Effect": "Allow"
    }
  ]
}

EOF
}

### ROUTES ###

# locals {
#   fw_interfaces = {
#     for k, v in {
#       for k2, v2 in module.vmseries :
#       k2 => v2.interfaces
#     } :
#     k => {
#       for iface_key, iface in v :
#       iface_key => iface.id
#       if strcontains(iface_key, "vlan")
#     }
#   }

#   fw_route_tables = [
#     for k, v in module.subnet_sets :
#     v
#     if strcontains(k, "vlan")
#   ]

#   fw_default_routes = merge([
#     for fw_name, eni_map in local.fw_interfaces : merge([
#       for rt_data in local.fw_route_tables : {
#         for az, rt_id in rt_data.unique_route_table_ids :
#         "${fw_name}-${rt_data.subnet_names[az]}-${az}" => {
#           route_table_id = rt_id
#           eni_id         = eni_map[regex("vlan[0-9]+", rt_data.subnet_names[az])]
#         }
#         if can(eni_map[regex("vlan[0-9]+", rt_data.subnet_names[az])])
#       }
#     ]...)
#   ]...)
# }

# resource "aws_route" "fw_default" {
#   for_each = local.fw_default_routes

#   route_table_id         = each.value.route_table_id
#   destination_cidr_block = "0.0.0.0/0"
#   network_interface_id   = each.value.eni_id
# }

locals {
  fw_default_routes_list = flatten([
    for fw_name in keys(module.vmseries) : [
      for subnet_key in keys(module.subnet_sets) : [
        for az in keys(module.subnet_sets[subnet_key].subnet_names) : {
          key        = "${fw_name}-${subnet_key}-${az}"
          fw_name    = fw_name
          subnet_key = subnet_key
          az         = az
          vlan_key   = regex("vlan[0-9]+", subnet_key)
        }
        if strcontains(subnet_key, "vlan")
      ]
    ]
  ])

  fw_default_routes = {
    for r in local.fw_default_routes_list :
    r.key => r
  }
}

resource "aws_route" "fw_default" {
  for_each = local.fw_default_routes

  route_table_id         = module.subnet_sets[each.value.subnet_key].unique_route_table_ids[each.value.az]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.vmseries[each.value.fw_name].interfaces[each.value.vlan_key].id
}