output "report_bucket" {
  value = aws_s3_bucket.report.id
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.main.arn
}

output "resource_explorer_view_name" {
  value = var.resource_explorer_view_name
}

output "resolver_lambda" {
  value = aws_lambda_function.resolver.function_name
}

output "inventory_lambda" {
  value = aws_lambda_function.inventory.function_name
}

output "apply_tags_lambda" {
  value = aws_lambda_function.apply_tags.function_name
}

output "verify_tags_lambda" {
  value = aws_lambda_function.verify_tags.function_name
}
