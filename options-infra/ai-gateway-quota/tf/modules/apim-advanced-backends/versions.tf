terraform {
  required_version = ">= 1.5"
  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = ">= 2.0"
    }
  }
}
