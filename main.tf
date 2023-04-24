################################################################################
# Load Vendor Corp Shared Infra
################################################################################
module "shared" {
  source                   = "git::ssh://git@github.com/vendorcorp/terraform-shared-infrastructure.git?ref=v0.5.0"
  environment              = var.environment
  default_eks_cluster_name = "vendorcorp-us-east-2-63pl3dng"
}

################################################################################
# PostgreSQL Provider
################################################################################
provider "postgresql" {
  scheme          = "awspostgres"
  host            = module.shared.pgsql_cluster_endpoint_write
  port            = module.shared.pgsql_cluster_port
  database        = "postgres"
  username        = module.shared.pgsql_cluster_master_username
  password        = var.pgsql_password
  sslmode         = "require"
  connect_timeout = 15
  superuser       = false
}

# --------------------------------------------------------------------------
# Create a unique database for Keycloak
# --------------------------------------------------------------------------
resource "postgresql_role" "keycloak" {
  name     = local.pg_user_username
  login    = true
  password = local.pg_user_password
}

resource "postgresql_grant_role" "grant_root" {
  role              = module.shared.pgsql_cluster_master_username
  grant_role        = postgresql_role.keycloak.name
  with_admin_option = true
}

resource "postgresql_database" "keycloak" {
  name              = local.pg_database_name
  owner             = local.pg_user_username
  template          = "template0"
  lc_collate        = "C"
  connection_limit  = -1
  allow_connections = true
}

################################################################################
# Connect to our k8s Cluster
################################################################################
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = module.shared.eks_cluster_arn
}

################################################################################
# Create Deployment for Keycloak
################################################################################
resource "kubernetes_deployment" "keycloak_deployment" {
  metadata {
    name      = "keycloak"
    namespace = module.shared.namespace_shared_core_name
    labels = {
      app = "keycloak"
    }
  }

  spec {
    replicas = 1

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
          instancegroup = "shared"
        }
        container {
          image = "quay.io/keycloak/keycloak:21.0.2"
          name  = "keycloak"

          args = ["start", "--hostname=keycloak.corp.${module.shared.dns_zone_public_name}"]

          env {
            name  = "KEYCLOAK_ADMIN"
            value = "admin"
          }

          env {
            name  = "KEYCLOAK_ADMIN_PASSWORD"
            value = local.keycloak_admin_password
          }

          env {
            name  = "KC_PROXY"
            value = "edge"
          }

          env {
            name  = "KC_DB"
            value = "postgres"
          }

          env {
            name  = "KC_DB_URL"
            value = "jdbc:postgresql://${module.shared.pgsql_cluster_endpoint_write}:${module.shared.pgsql_cluster_port}/${local.pg_database_name}"
          }

          env {
            name  = "KC_DB_USERNAME"
            value = local.pg_user_username
          }

          env {
            name  = "KC_DB_PASSWORD"
            value = local.pg_user_password
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
              path = "/realms/master"
              port = 8080
            }
          }

          # liveness_probe {
          #   http_get {
          #     path = "/nginx_status"
          #     port = 80

          #     http_header {
          #       name  = "X-Custom-Header"
          #       value = "Awesome"
          #     }
          #   }

          #   initial_delay_seconds = 3
          #   period_seconds        = 3
          # }
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
    namespace = module.shared.namespace_shared_core_name
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

    type = "NodePort"
  }
  # wait_for_load_balancer = true
}

################################################################################
# Create Ingress for Keycloak
################################################################################
resource "kubernetes_ingress_v1" "keycloak" {
  metadata {
    name      = "keycloak-ingress"
    namespace = module.shared.namespace_shared_core_name
    labels = {
      app = "keycloak"
    }
    annotations = {
      "kubernetes.io/ingress.class"               = "alb"
      "alb.ingress.kubernetes.io/group.name"      = "vencorcorp-shared-core"
      "alb.ingress.kubernetes.io/scheme"          = "internal"
      "alb.ingress.kubernetes.io/certificate-arn" = module.shared.vendorcorp_net_cert_arn
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

################################################################################
# Add/Update DNS for Load Balancer Ingress
################################################################################
resource "aws_route53_record" "keycloak_dns" {
  zone_id = module.shared.dns_zone_public_id
  name    = "keycloak.corp"
  type    = "CNAME"
  ttl     = "300"
  records = [
    kubernetes_ingress_v1.keycloak.status.0.load_balancer.0.ingress.0.hostname
  ]
}
