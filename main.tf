data "azurerm_client_config" "current" {}

#----------------------------------------------------------------------------------------
# resourcegroups
#----------------------------------------------------------------------------------------

data "azurerm_resource_group" "rg" {
  for_each = var.vaults

  name = each.value.resourcegroup
}

#----------------------------------------------------------------------------------------
# Generate random id
#----------------------------------------------------------------------------------------

resource "random_string" "random" {
  for_each = var.vaults

  length    = 3
  min_lower = 3
  special   = false
  numeric   = false
  upper     = false
}

#----------------------------------------------------------------------------------------
# keyvaults
#----------------------------------------------------------------------------------------

resource "azurerm_key_vault" "keyvault" {
  for_each = var.vaults

  name                = "kv${var.company}${each.key}${var.env}${var.region}${random_string.random[each.key].result}"
  resource_group_name = data.azurerm_resource_group.rg[each.key].name
  location            = data.azurerm_resource_group.rg[each.key].location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = each.value.sku

  enabled_for_deployment          = try(each.value.enable.deployment, true)
  enabled_for_disk_encryption     = try(each.value.enable.disk_encryption, true)
  enabled_for_template_deployment = try(each.value.enable.template_deployment, true)
  purge_protection_enabled        = try(each.value.enable.purge_protection, false)
  enable_rbac_authorization       = try(each.value.enable.rbac_auth, false)
  public_network_access_enabled   = try(each.value.enable.public_network_access, true)
  soft_delete_retention_days      = try(each.value.retention_in_days, null)

  # dynamic "network_acls" {
  #   for_each = var.vaults
  #   # for_each = {
  #   #   for k, v in try(each.value.network_acls, {}) : k => v
  #   # }

  #   content {
  #     default_action             = each.value.network_acls.default_action
  #     bypass                     = each.value.network_acls.bypass
  #     ip_rules                   = try(each.value.network_acls.ip_rules, [])
  #     virtual_network_subnet_ids = try(each.value.network_acls.subnet_ids, [])
  #   }
  # }
}

#----------------------------------------------------------------------------------------
# role assignments
#----------------------------------------------------------------------------------------

resource "azurerm_role_assignment" "current" {
  for_each = var.vaults

  scope                = azurerm_key_vault.keyvault[each.key].id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

#----------------------------------------------------------------------------------------
# certificate issuers
#----------------------------------------------------------------------------------------

resource "azurerm_key_vault_certificate_issuer" "issuer" {
  for_each = {
    for issuer in local.issuer : "${issuer.kv_key}.${issuer.issuer_key}" => issuer
  }

  name          = each.value.name
  org_id        = each.value.org_id
  key_vault_id  = each.value.key_vault_id
  provider_name = each.value.provider_name
  account_id    = each.value.account_id
  password      = each.value.password //pat certificate authority

  depends_on = [
    azurerm_role_assignment.current
  ]
}

#----------------------------------------------------------------------------------------
# certificate contacts
#----------------------------------------------------------------------------------------

resource "azurerm_key_vault_certificate_contacts" "example" {
  for_each = {
    for k, v in var.vaults : k => v
  }

  key_vault_id = azurerm_key_vault.keyvault[each.key].id

  dynamic "contact" {
    for_each = {
      for k, v in try(each.value.contacts, {}) : k => v
    }

    content {
      email = contact.value.email
      name  = try(contact.value.name, null)
      phone = try(contact.value.phone, null)
    }
  }

  depends_on = [
    azurerm_role_assignment.current
  ]
}

#----------------------------------------------------------------------------------------
# keys
#----------------------------------------------------------------------------------------

resource "azurerm_key_vault_key" "kv_keys" {
  for_each = {
    for key in local.keys : "${key.kv_key}.${key.k_key}" => key
  }

  name            = each.value.name
  key_vault_id    = each.value.key_vault_id
  key_type        = each.value.key_type
  key_size        = each.value.key_size
  key_opts        = each.value.key_opts
  curve           = each.value.curve
  not_before_date = each.value.not_before_date
  expiration_date = each.value.expiration_date

  depends_on = [
    azurerm_role_assignment.current
  ]
}

#----------------------------------------------------------------------------------------
# secrets
#----------------------------------------------------------------------------------------

resource "random_password" "password" {
  for_each = {
    for secret in local.secrets : "${secret.kv_key}.${secret.secret_key}" => secret
  }

  length      = each.value.length
  special     = each.value.special
  min_lower   = each.value.min_lower
  min_upper   = each.value.min_upper
  min_special = each.value.min_special
  min_numeric = each.value.min_numeric
}

resource "azurerm_key_vault_secret" "secret" {
  for_each = {
    for secret in local.secrets : "${secret.kv_key}.${secret.secret_key}" => secret
  }

  name         = each.value.name
  value        = random_password.password[each.key].result
  key_vault_id = each.value.key_vault_id

  depends_on = [
    azurerm_role_assignment.current
  ]
}

# ----------------------------------------------------------------------------------------
# certificates
# ----------------------------------------------------------------------------------------

resource "azurerm_key_vault_certificate" "cert" {
  for_each = {
    for cert in local.certs : "${cert.kv_key}.${cert.cert_key}" => cert
  }

  name         = each.value.name
  key_vault_id = each.value.key_vault_id

  certificate_policy {
    issuer_parameters {
      name = each.value.issuer
    }
    key_properties {
      exportable = each.value.issuer == "Self" ? true : false
      key_type   = each.value.key_type
      key_size   = each.value.key_size
      reuse_key  = each.value.reuse_key
    }
    secret_properties {
      content_type = each.value.content_type
    }
    x509_certificate_properties {
      subject            = each.value.subject
      validity_in_months = each.value.validity_in_months
      key_usage = [
        "cRLSign",
        "dataEncipherment",
        "digitalSignature",
        "keyAgreement",
        "keyCertSign",
        "keyEncipherment",
      ]
    }
  }
  depends_on = [
    azurerm_role_assignment.current
  ]
}