################################################################################
# Load Vendor Corp Shared Infra
################################################################################
module "shared" {
  source                   = "git::ssh://git@github.com/vendorcorp/terraform-shared-infrastructure.git?ref=v0.1.2"
  environment              = var.environment
  default_eks_cluster_name = "vendorcorp-us-east-2-63pl3dng"
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
          image = "quay.io/keycloak/keycloak:17.0.0"
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
# Create Endpoint for Keycloak
################################################################################
# resource "kubernetes_endpoints" "keycloak_endpoint" {
#   metadata {
#     name = "keycloak-endpoint"
#     labels = {
#       app = "keycloak"
#     }
#   }

#   subset {

#   }
# }

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
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }

    type = "LoadBalancer"
  }
  wait_for_load_balancer = true
}

################################################################################
# Create Ingress for Keycloak
################################################################################
# resource "kubernetes_ingress" "keycloak_ingress" {
#   wait_for_load_balancer = true

#   metadata {
#     name      = "keycloak"
#     namespace = module.shared.namespace_shared_core_name
#     annotations = {
#       "kubernetes.io/ingress.class"      = "alb"
#       "alb.ingress.kubernetes.io/scheme" = "internal"
#     }
#   }

#   spec {
#     rule {
#       host = "keycloak.corp.${module.shared.dns_zone_public_name}"
#       http {
#         path {
#           backend {
#             service_name = kubernetes_service.keycloak_service.metadata.0.name
#             service_port = 8080
#           }

#           path = "/"
#         }
#       }
#     }
#   }
# }

################################################################################
# Add/Update DNS for Load Balancer Ingress
################################################################################
resource "aws_route53_record" "keycloak_dns" {
  zone_id = module.shared.dns_zone_public_id
  name    = "keycloak.corp"
  type    = "CNAME"
  ttl     = "300"
  # records = [kubernetes_ingress.keycloak_ingress.status.0.load_balancer.0.ingress.0.hostname]
  records = [
    kubernetes_service.keycloak_service.status.0.load_balancer.0.ingress.0.hostname
  ]
}
