resource "random_string" "admin_password" {
  length  = 20
  special = true
}

locals {
  keycloak_admin_password = random_string.admin_password.result
}
