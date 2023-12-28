terraform {
  required_version = ">= 1.4.5"
  required_providers {
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.15.0"
    }
  }
}


################################################################################
# Load Vendor Corp Shared Infra
################################################################################
module "shared" {
  source                   = "git::ssh://git@github.com/vendorcorp/terraform-shared-infrastructure.git?ref=v0.6.1"
  environment              = var.environment
}

################################################################################
# Connect to our k8s Cluster
################################################################################
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = module.shared.eks_cluster_arn
}

################################################################################
# PostgreSQL Provider
################################################################################
provider "postgresql" {
  scheme          = "awspostgres"
  host            = module.shared.pgsql_cluster_endpoint_write
  port            = module.shared.pgsql_cluster_port
  database        = "postgres"
  username        = var.pg_admin_username
  password        = var.pg_admin_password
  sslmode         = "require"
  connect_timeout = 15
  superuser       = false
}

################################################################################
# Create a Database for Keycloak
################################################################################
resource "postgresql_role" "keycloak" {
  name     = local.pgsql_user_username
  login    = true
  password = local.pgsql_user_password
}

# resource "postgresql_grant_role" "grant_root" {
#   role              = var.pg_admin_username
#   grant_role        = postgresql_role.keycloak.name
#   with_admin_option = true
# }

resource "postgresql_database" "keycloak" {
  name              = local.pgsql_database_name
  owner             = local.pgsql_user_username
  template          = "template0"
  lc_collate        = "C"
  connection_limit  = -1
  allow_connections = true
}

################################################################################
# Create Namespace
################################################################################
resource "kubernetes_namespace" "keycloak" {
  metadata {
    name = var.namespace
  }
}

################################################################################
# Create Secret
################################################################################
resource "kubernetes_secret" "keycloak" {
  metadata {
    name      = "keycloak-secrets"
    namespace = var.namespace
  }

  data = {
    "keycloak_admin_password" = local.keycloak_admin_password
    "keycloak_db_username" = local.pgsql_user_username
    "keycloak_db_password" = local.pgsql_user_password
  }

  type = "Opaque"
}

################################################################################
# Create Deployment for Keycloak
################################################################################
resource "kubernetes_deployment" "keycloak_deployment" {
  metadata {
    name      = "keycloak"
    namespace = var.namespace
    labels = {
      app = "keycloak"
    }
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = "keycloak"
      }
    }

    template {
      metadata {
        labels = {
          app = "keycloak"
        }
      }

      spec {

        node_selector = {
          instancegroup = "vendorcorp-core"
        }

        toleration {
          effect = "NoSchedule"
          key = "dedicated"
          operator = "Equal"
          value = "vendorcorp-core"
        }

        container {
          image = "quay.io/keycloak/keycloak:23.0.3"
          name  = "keycloak"

          args = ["start"]

          env {
            name = "JAVA_OPTS_APPEND"
            value = "-Djgroups.dns.query=keycloak-headless"
          }

          env {
            name = "KC_CACHE"
            value = "ispn"
          }

          env {
            name = "KC_CACHE_STACK"
            value = "kubernetes"
          }

          env {
            name = "KC_DB"
            value = "postgres"
          }

          env {
            name = "KC_DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "keycloak-secrets"
                key  = "keycloak_db_password"
              }
            }
          }

          env {
            name = "KC_DB_URL"
            value = "jdbc:postgresql://${module.shared.pgsql_cluster_endpoint_write}/${local.pgsql_database_name}"
          }

          env {
            name = "KC_DB_USERNAME"
            value_from {
              secret_key_ref {
                name = "keycloak-secrets"
                key  = "keycloak_db_username"
              }
            }
          }

          # env {
          #   name = "KC_FEATURES"
          #   value = "token-exchange"
          # }

          env {
            name = "KC_HEALTH_ENABLED"
            value = "true"
          }

          env {
            name = "KC_HOSTNAME"
            value = "keycloak.corp.${module.shared.dns_zone_public_name}"
          }

          env {
            name = "KC_METRICS_ENABLED"
            value = "true"
          }

          env {
            name  = "KEYCLOAK_ADMIN"
            value = "admin"
          }

          env {
            name  = "KEYCLOAK_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = "keycloak-secrets"
                key  = "keycloak_admin_password"
              }
            }
          }

          env {
            name  = "KC_PROXY"
            value = "edge"
          }

          # resources {
          #   limits = {
          #     cpu    = "0.5"
          #     memory = "512Mi"
          #   }
          #   requests = {
          #     cpu    = "250m"
          #     memory = "50Mi"
          #   }
          # }

          readiness_probe {
            http_get {
              path = "/health/ready"
              port = 8080
            }
          }

          volume_mount {
            mount_path = "/keycloak-secrets"
            name       = "keycloak-secrets"
          }
        }

        volume {
          name = "keycloak-secrets"
          secret {
            secret_name = "keycloak-secrets"
          }
        }
      }
    }
  }
}

################################################################################
# Create Service for Keycloak
################################################################################
resource "kubernetes_service" "keycloak_service" {
  metadata {
    name      = "keycloak-service"
    namespace = var.namespace
    labels = {
      app = "keycloak"
    }
  }
  spec {
    selector = {
      app = kubernetes_deployment.keycloak_deployment.metadata.0.labels.app
    }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }

     port {
      name        = "infinispan"
      port        = 7800
      target_port = 7800
      protocol    = "TCP"
    }

    type = "NodePort"
  }
}

################################################################################
# Create headless Service for Keycloak Cluster discovery
################################################################################
resource "kubernetes_service" "keycloak_headless_service" {
  metadata {
    name      = "keycloak-headless"
    namespace = var.namespace
    labels = {
      app = "keycloak"
    }
  }
  spec {
    selector = {
      app = kubernetes_deployment.keycloak_deployment.metadata.0.labels.app
    } 

    cluster_ip = "None"
    type = "ClusterIP"
  }
}

################################################################################
# Create Ingress for Keycloak
################################################################################
resource "kubernetes_ingress_v1" "keycloak" {
  metadata {
    name      = "keycloak-ingress"
    namespace = var.namespace
    labels = {
      app = "keycloak"
    }
    annotations = {
      "kubernetes.io/ingress.class"               = "alb"
      "alb.ingress.kubernetes.io/group.name"      = "vendorcorp-core"
      "alb.ingress.kubernetes.io/scheme"          = "internal"
      "alb.ingress.kubernetes.io/certificate-arn" = module.shared.vendorcorp_net_cert_arn
      "external-dns.alpha.kubernetes.io/hostname" = "keycloak.corp.${module.shared.dns_zone_public_name}"
    }
  }

  spec {
    rule {
      host = "keycloak.corp.${module.shared.dns_zone_public_name}"
      http {
        path {
          path = "/*"
          backend {
            service {
              name = "keycloak-service"
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }

  wait_for_load_balancer = true
}