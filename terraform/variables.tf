# ── Required ──────────────────────────────────────────────────────────────────

variable "aws_region" {
  type        = string
  description = "AWS region to deploy into (e.g. us-east-1)."
}

variable "product_code" {
  type        = string
  description = "Tag value used for PRM attribution (your APN product code)."
}

# ── Authentication ─────────────────────────────────────────────────────────────
# Uncomment the option that matches your authentication method.
# Only one method should be active at a time.

# Option 1 – Named AWS CLI profile
# variable "aws_profile" {
#   type        = string
#   default     = null
#   description = "AWS CLI profile to use. Leave unset to use environment variables or the default profile."
# }

# Option 2 – Explicit account ID (used with assume_role in main.tf)
# variable "aws_account_id" {
#   type        = string
#   description = "Target AWS account ID to deploy into."
# }

# Option 3 – IAM role assumption (cross-account or CI/CD)
# variable "assume_role_arn" {
#   type        = string
#   default     = null
#   description = "IAM role ARN to assume for deployment (e.g. arn:aws:iam::123456789012:role/DeploymentRole)."
# }

# Option 4 – External ID for role assumption (required by some cross-account trust policies)
# variable "assume_role_external_id" {
#   type        = string
#   default     = null
#   description = "External ID to pass when assuming the IAM role."
# }

# ── Tagging ────────────────────────────────────────────────────────────────────

variable "partner_central_id" {
  type        = string
  default     = "aws-apn-id"
  description = "Tag key used for PRM attribution. Must be aws-apn-id."
}

# ── Resource Explorer ──────────────────────────────────────────────────────────

variable "resource_explorer_view_name" {
  type        = string
  default     = "prm-attribution-view"
  description = "Resource Explorer view name to reuse or create."
}

variable "inventory_query" {
  type        = string
  default     = "resourcetype.supports:tags"
  description = "Resource Explorer query to discover taggable resources."
}
