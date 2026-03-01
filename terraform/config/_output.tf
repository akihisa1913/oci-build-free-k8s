# output "longhorn_login" {
#   value = module.longhorn.longhorn_login
#
#   sensitive = true
# }

output "nsg_id" {
  value = module.ingress.nsg_id
}
