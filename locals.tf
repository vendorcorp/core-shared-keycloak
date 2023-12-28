resource "random_string" "pg_suffix" {
  length  = 8
  special = false
}

resource "random_string" "keycloak_admin_password" {
  length  = 20
  special = true
}

resource "random_string" "pgsql_user_password" {
  length  = 16
  special = false
}

locals {
  keycloak_admin_password = random_string.keycloak_admin_password.result
  pgsql_database_name = "keycloak_${random_string.pg_suffix.result}"
  pgsql_user_username = "keycloak_${random_string.pg_suffix.result}"
  pgsql_user_password = random_string.pgsql_user_password.result
}
