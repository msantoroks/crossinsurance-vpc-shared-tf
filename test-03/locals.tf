locals {
  config_raw = yamldecode(file("${path.module}/config/environments.yaml"))

  environments = {
    for e in local.config_raw.environments : e.name => e
  }

  shared   = local.environments["shared"]
  workload = local.environments["test-03"]
}
