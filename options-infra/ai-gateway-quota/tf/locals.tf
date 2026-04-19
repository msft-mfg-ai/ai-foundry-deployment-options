locals {
  # Build contract entries: { contractName -> config }
  contract_entries = {
    for contract in var.access_contracts : contract.name => {
      name         = contract.name
      priority     = contract.priority
      monthlyQuota = contract.monthly_quota
      environment  = contract.environment
      identities = [
        for id in contract.identities : {
          value       = id.value
          displayName = id.display_name
          claimName   = id.claim_name
        }
      ]
      models = {
        for model in contract.models : model.name => {
          tpm    = model.tpm
          ptuTpm = model.ptu_tpm
        }
      }
    }
  }

  # Build identity entries (flat list for prefix matching)
  identity_entries = flatten([
    for contract in var.access_contracts : [
      for id in contract.identities : {
        value       = id.value
        claimName   = id.claim_name
        displayName = id.display_name
        contract    = contract.name
      }
    ]
  ])

  # PTU capacity from backends module (will be populated after module runs)
  # For now, compute from foundry_instances directly
  ptu_capacity_per_model = {
    for model in distinct(flatten([for inst in var.foundry_instances : [for d in inst.deployments : d.model_name]])) :
    model => sum(concat([0], flatten([
      for inst in var.foundry_instances : [
        for d in inst.deployments : d.ptu_capacity_tpm if d.model_name == model
      ] if inst.is_ptu
    ])))
  }

  # The complete contract map JSON
  contract_map = {
    contracts   = local.contract_entries
    identities  = local.identity_entries
    ptuCapacity = local.ptu_capacity_per_model
  }

  contract_map_json = jsonencode(local.contract_map)
}
