variable "partner_central_id" {
  type        = string
  default     = "aws-apn-id"
  description = "Tag key used for PRM attribution."
}

variable "product_code" {
  type        = string
  description = "Tag value used for PRM attribution."
}

variable "inventory_query" {
  type        = string
  default     = "resourcetype.supports:tags"
  description = "Resource Explorer query to discover taggable resources."
}

variable "resource_explorer_view_name" {
  type        = string
  default     = "prm-attribution-view"
  description = "Resource Explorer view name to reuse or create."
}
