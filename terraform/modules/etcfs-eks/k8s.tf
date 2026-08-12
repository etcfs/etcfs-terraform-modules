# EtcFS's own etcd + daemon pair, and the CSI driver, deployed onto the
# cluster this module just created.
#
# This is what the manual EKS validation run
# (docs/reports/csi-reports/2026-08-12-eks-csi-driver-validation.md) did by
# hand with kubectl/helm; expressing it here means `terraform apply` alone
# reproduces that whole cluster, including the shared volume's ID being wired
# through automatically instead of queried and pasted in after the fact.

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

resource "kubernetes_namespace_v1" "etcfs" {
  metadata {
    name = var.namespace
  }
  depends_on = [aws_instance.node, kubernetes_config_map_v1_data.aws_auth]
}

resource "kubernetes_config_map_v1" "volume_id" {
  metadata {
    name      = "etcfs-volume"
    namespace = kubernetes_namespace_v1.etcfs.metadata[0].name
  }
  data = {
    # Wired straight from the resource this module created — the manual run
    # this replaces had to query it with the AWS CLI after the fact.
    "volume-id" = aws_ebs_volume.shared.id
  }
}

resource "kubernetes_deployment_v1" "etcd" {
  metadata {
    name      = "etcd"
    namespace = kubernetes_namespace_v1.etcfs.metadata[0].name
    labels    = { app = "etcd" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "etcd" } }
    template {
      metadata { labels = { app = "etcd" } }
      spec {
        container {
          name  = "etcd"
          image = var.etcd_image
          args = [
            "etcd",
            "--data-dir=/etcd-data",
            "--listen-client-urls=http://0.0.0.0:2379",
            "--advertise-client-urls=http://etcd.${var.namespace}.svc.cluster.local:2379",
            "--auto-compaction-mode=revision",
            "--auto-compaction-retention=100000",
            "--quota-backend-bytes=8589934592",
          ]
          port { container_port = 2379 }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "etcd" {
  metadata {
    name      = "etcd"
    namespace = kubernetes_namespace_v1.etcfs.metadata[0].name
  }
  spec {
    selector = { app = "etcd" }
    port {
      port        = 2379
      target_port = 2379
    }
  }
}

# etcfuse-meta + etcfuse, one pair per node — matches
# deploy/docker/docker-compose.yml's pairing, moved onto the nodes this
# module created against the io2 volume it also created.
resource "kubernetes_daemon_set_v1" "etcfs" {
  metadata {
    name      = "etcfs-daemon"
    namespace = kubernetes_namespace_v1.etcfs.metadata[0].name
  }
  spec {
    selector { match_labels = { app = "etcfs-daemon" } }
    template {
      metadata { labels = { app = "etcfs-daemon" } }
      spec {
        host_pid = true

        volume {
          name = "run-etcfuse"
          host_path {
            path = "/run/etcfuse"
            type = "DirectoryOrCreate"
          }
        }
        volume {
          name = "mnt-etcfs"
          host_path {
            path = var.mount_path
            type = "DirectoryOrCreate"
          }
        }
        volume {
          name = "dev"
          host_path { path = "/dev" }
        }

        container {
          name  = "etcfuse-meta"
          image = var.etcfuse_meta_image
          security_context { privileged = true }
          args = [
            "--listen=/run/etcfuse/etcfuse.sock",
            "--notify-socket=/run/etcfuse/etcfuse-notify.sock",
            "--node-id=$(NODE_NAME)",
            "--etcd-endpoints=http://etcd.${var.namespace}.svc.cluster.local:2379",
            "--volume-id=$(ETCFS_VOLUME_ID)",
            "--lease-ttl=${var.lease_ttl}",
            "--log-level=2",
          ]
          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          env {
            name = "ETCFS_VOLUME_ID"
            value_from {
              config_map_key_ref {
                name = kubernetes_config_map_v1.volume_id.metadata[0].name
                key  = "volume-id"
              }
            }
          }
          volume_mount {
            name       = "run-etcfuse"
            mount_path = "/run/etcfuse"
          }
          volume_mount {
            name       = "dev"
            mount_path = "/dev"
          }
        }

        container {
          name  = "etcfuse"
          image = var.etcfuse_image
          security_context { privileged = true }
          args = [
            "--socket=/run/etcfuse/etcfuse.sock",
            "--node-id=$(NODE_NAME)",
            "--log-level=2",
            var.mount_path,
          ]
          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          volume_mount {
            name       = "run-etcfuse"
            mount_path = "/run/etcfuse"
          }
          volume_mount {
            name              = "mnt-etcfs"
            mount_path        = var.mount_path
            mount_propagation = "Bidirectional"
          }
        }
      }
    }
  }

  depends_on = [aws_volume_attachment.shared]
}

# ---- CSI driver, via its own Helm chart ----

resource "helm_release" "etcfs_csi" {
  name      = "etcfs-csi"
  chart     = "${path.module}/../../../../csi/deploy/helm/etcfs-csi"
  namespace = kubernetes_namespace_v1.etcfs.metadata[0].name

  values = [yamlencode({
    driverName = var.csi_driver_name
    image = {
      repository = var.csi_image_repository
      tag        = var.csi_image_tag
    }
    mountPath = var.mount_path
    etcd = {
      endpoints = "http://etcd.${var.namespace}.svc.cluster.local:2379"
    }
    storageClass = {
      name = var.storage_class_name
    }
  })]

  # The CSI controller provisions by creating a directory through the shared
  # filesystem, so it must not be scheduled before that filesystem is
  # actually mounted anywhere.
  depends_on = [kubernetes_daemon_set_v1.etcfs]
}
