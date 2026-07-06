terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Option 1 – Named AWS CLI profile (uncomment var.aws_profile in variables.tf)
  # profile = var.aws_profile

  # Option 2 – IAM role assumption (uncomment var.assume_role_arn in variables.tf)
  # dynamic "assume_role" {
  #   for_each = var.assume_role_arn != null ? [1] : []
  #   content {
  #     role_arn    = var.assume_role_arn
  #     external_id = var.assume_role_external_id # remove if not required
  #   }
  # }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── S3 ────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "report" {
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "report" {
  bucket = aws_s3_bucket.report.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── IAM – Lambda ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "apn-attribution-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "apn-layered-tagging-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "LambdaLogging"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Sid    = "ResourceExplorerInventory"
        Effect = "Allow"
        Action = [
          "resource-explorer-2:Search",
          "resource-explorer-2:GetView",
          "resource-explorer-2:ListViews",
          "resource-explorer-2:CreateView"
        ]
        Resource = "*"
      },
      {
        Sid    = "GenericTaggingApi"
        Effect = "Allow"
        Action = ["tag:TagResources", "tag:GetResources", "tag:GetTagKeys", "tag:GetTagValues"]
        Resource = "*"
      },
      {
        Sid      = "Ec2Tagging"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "*"
      },
      {
        Sid    = "ServerlessWorkflowAndLogsTagging"
        Effect = "Allow"
        Action = ["lambda:TagResource", "states:TagResource", "events:TagResource", "logs:TagResource"]
        Resource = "*"
      },
      {
        Sid      = "StorageTagging"
        Effect   = "Allow"
        Action   = ["s3:GetBucketTagging", "s3:PutBucketTagging"]
        Resource = "*"
      },
      {
        Sid    = "DatabaseAndCacheTagging"
        Effect = "Allow"
        Action = [
          "rds:AddTagsToResource",
          "dynamodb:TagResource",
          "elasticache:AddTagsToResource",
          "memorydb:TagResource"
        ]
        Resource = "*"
      },
      {
        Sid      = "AnalyticsAndObservabilityTagging"
        Effect   = "Allow"
        Action   = ["athena:TagResource", "xray:TagResource"]
        Resource = "*"
      },
      {
        Sid      = "ApplicationServicesTagging"
        Effect   = "Allow"
        Action   = ["apprunner:TagResource"]
        Resource = "*"
      },
      {
        Sid      = "CloudFormationReadSupport"
        Effect   = "Allow"
        Action   = ["cloudformation:DescribeStacks"]
        Resource = "*"
      },
      {
        Sid      = "S3ReportBucketAccess"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.report.arn}/*"
      }
    ]
  })
}

# ── IAM – Step Functions ──────────────────────────────────────────────────────

resource "aws_iam_role" "sfn" {
  name = "apn-attribution-stepfunctions-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "apn-attribution-stepfunctions-policy"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = [
        aws_lambda_function.resolver.arn,
        aws_lambda_function.inventory.arn,
        aws_lambda_function.apply_tags.arn,
        aws_lambda_function.verify_tags.arn
      ]
    }]
  })
}

# ── Lambda – archive helper ───────────────────────────────────────────────────

data "archive_file" "resolver" {
  type        = "zip"
  output_path = "${path.module}/.dist/resolver.zip"
  source {
    content  = <<-PYTHON
import boto3
import os
import time
import random
from botocore.exceptions import ClientError

rex = boto3.client("resource-explorer-2")
VIEW_NAME = os.environ.get("RESOURCE_EXPLORER_VIEW_NAME", "prm-attribution-view")

def lambda_handler(event, context):
    view_arn, action = resolve_view(VIEW_NAME)
    return {
        "resource_explorer_view_arn": view_arn,
        "resource_explorer_view_name": VIEW_NAME,
        "resolution_action": action
    }

def resolve_view(view_name):
    existing = find_view_by_name(view_name)
    if existing:
        wait_until_view_readable(existing)
        return existing, "reused_existing_view"
    try:
        response = rex.create_view(
            ViewName=view_name,
            IncludedProperties=[{"Name": "tags"}]
        )
        view_arn = response["View"]["ViewArn"]
        wait_until_view_readable(view_arn)
        return view_arn, "created_view"
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "Unknown")
        if error_code in ["ConflictException", "AlreadyExistsException", "ValidationException"]:
            existing = retry_find_view_by_name(view_name)
            if existing:
                wait_until_view_readable(existing)
                return existing, "reused_view_after_create_conflict"
        raise

def find_view_by_name(view_name):
    paginator = rex.get_paginator("list_views")
    for page in paginator.paginate():
        for view_arn in page.get("Views", []):
            if view_arn.rstrip("/").split("/")[-1] == view_name:
                return view_arn
            try:
                view = rex.get_view(ViewArn=view_arn).get("View", {})
                if view.get("Name") == view_name:
                    return view_arn
            except ClientError:
                continue
    return None

def retry_find_view_by_name(view_name, max_attempts=8):
    delay = 2
    for attempt in range(1, max_attempts + 1):
        existing = find_view_by_name(view_name)
        if existing:
            return existing
        sleep_time = delay + random.uniform(0, 1)
        print(f"View {view_name} not visible yet after create conflict. Attempt {attempt}/{max_attempts}. Retrying in {sleep_time:.1f}s")
        time.sleep(sleep_time)
        delay = min(delay * 2, 30)
    return None

def wait_until_view_readable(view_arn, max_attempts=8):
    delay = 2
    for attempt in range(1, max_attempts + 1):
        try:
            rex.get_view(ViewArn=view_arn)
            return
        except ClientError as e:
            if attempt == max_attempts:
                raise
            error_code = e.response.get("Error", {}).get("Code", "Unknown")
            sleep_time = delay + random.uniform(0, 1)
            print(f"View {view_arn} not readable yet: {error_code}. Attempt {attempt}/{max_attempts}. Retrying in {sleep_time:.1f}s")
            time.sleep(sleep_time)
            delay = min(delay * 2, 30)
PYTHON
    filename = "index.py"
  }
}

data "archive_file" "inventory" {
  type        = "zip"
  output_path = "${path.module}/.dist/inventory.zip"
  source {
    content  = <<-PYTHON
import boto3
import json
import os
import time
import random
from datetime import datetime, timezone
from botocore.exceptions import ClientError

rex = boto3.client("resource-explorer-2")
s3 = boto3.client("s3")
sts = boto3.client("sts")

BUCKET = os.environ["REPORT_BUCKET"]
QUERY = os.environ.get("INVENTORY_QUERY", "resourcetype.supports:tags")
TAG_KEY = os.environ.get("TAG_KEY", "apn-id")
TAG_VALUE = os.environ["TAG_VALUE"]

EXCLUDED_RESOURCE_TYPES = {"cloudformation:stack", "athena:datacatalog"}
EXCLUDED_ARN_CONTAINS = [
    ":datacatalog/AwsDataCatalog",
    ":user/default",
    ":acl/open-access",
    ":parametergroup/default.memorydb-",
]

def lambda_handler(event, context):
    account_id = sts.get_caller_identity()["Account"]
    view_arn = event.get("resource_explorer_view_arn")
    if not view_arn:
        raise ValueError("Missing resource_explorer_view_arn.")
    resources = []
    for item in search_resources_with_retry(view_arn, QUERY):
        arn = item.get("Arn")
        region = item.get("Region")
        service = item.get("Service")
        resource_type = item.get("ResourceType")
        if not arn or not region:
            continue
        if is_excluded(arn, service, resource_type):
            continue
        resources.append({"account_id": account_id, "arn": arn, "region": region, "service": service, "resource_type": resource_type})
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    key = f"inventory/apn-inventory-{timestamp}.json"
    payload = {"account_id": account_id, "resource_explorer_view_arn": view_arn, "tag_key": TAG_KEY, "tag_value": TAG_VALUE, "query": QUERY, "generated_at": timestamp, "resources": resources}
    s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(payload, indent=2).encode("utf-8"), ContentType="application/json")
    return {"report_bucket": BUCKET, "inventory_key": key, "resource_explorer_view_arn": view_arn, "tag_key": TAG_KEY, "tag_value": TAG_VALUE, "resource_count": len(resources)}

def search_resources_with_retry(view_arn, query_string, max_attempts=8):
    delay = 2
    retryable_errors = {"ThrottlingException", "TooManyRequestsException", "InternalServerException", "ServiceUnavailableException", "ValidationException", "ResourceNotFoundException"}
    for attempt in range(1, max_attempts + 1):
        try:
            paginator = rex.get_paginator("search")
            results = []
            for page in paginator.paginate(ViewArn=view_arn, QueryString=query_string):
                results.extend(page.get("Resources", []))
            return results
        except ClientError as e:
            error_code = e.response.get("Error", {}).get("Code", "Unknown")
            error_message = e.response.get("Error", {}).get("Message", "")
            if error_code not in retryable_errors:
                raise
            if attempt == max_attempts:
                raise RuntimeError(f"Resource Explorer search failed after {max_attempts} attempts. Last error: {error_code} - {error_message}")
            sleep_time = delay + random.uniform(0, 1.5)
            print(f"Resource Explorer search attempt {attempt}/{max_attempts} failed with {error_code}: {error_message}. Retrying in {sleep_time:.1f}s")
            time.sleep(sleep_time)
            delay = min(delay * 2, 30)

def is_excluded(arn, service, resource_type):
    rt = (resource_type or "").lower()
    svc = (service or "").lower()
    if rt in EXCLUDED_RESOURCE_TYPES:
        return True
    if svc == "cloudformation":
        return True
    for marker in EXCLUDED_ARN_CONTAINS:
        if marker in arn:
            return True
    return False
PYTHON
    filename = "index.py"
  }
}

data "archive_file" "apply_tags" {
  type        = "zip"
  output_path = "${path.module}/.dist/apply_tags.zip"
  source {
    content  = <<-PYTHON
import boto3
import json
from datetime import datetime, timezone

s3 = boto3.client("s3")

def lambda_handler(event, context):
    bucket = event["report_bucket"]
    inventory_key = event["inventory_key"]
    tag_key = event["tag_key"]
    tag_value = event["tag_value"]
    inventory = json.loads(s3.get_object(Bucket=bucket, Key=inventory_key)["Body"].read())
    grouped = {}
    for resource in inventory.get("resources", []):
        arn = resource.get("arn")
        region = resource.get("region")
        if arn and region:
            grouped.setdefault(region, []).append(arn)
    results = []
    for region, arns in grouped.items():
        tagging = boto3.client("resourcegroupstaggingapi", region_name=region)
        for batch in chunks(arns, 20):
            response = tagging.tag_resources(ResourceARNList=batch, Tags={tag_key: tag_value})
            failures = response.get("FailedResourcesMap", {})
            for arn in batch:
                if arn in failures:
                    results.append({"arn": arn, "region": region, "status": "failed", "failure": failures[arn]})
                else:
                    results.append({"arn": arn, "region": region, "status": "tagged", "applied": {tag_key: tag_value}})
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    apply_key = f"apply-results/apn-apply-{timestamp}.json"
    s3.put_object(Bucket=bucket, Key=apply_key, Body=json.dumps(results, indent=2).encode("utf-8"), ContentType="application/json")
    return {"report_bucket": bucket, "inventory_key": inventory_key, "apply_results_key": apply_key, "tag_key": tag_key, "tag_value": tag_value, "processed": len(results), "tagged": sum(1 for r in results if r["status"] == "tagged"), "failed": sum(1 for r in results if r["status"] == "failed")}

def chunks(items, size):
    for i in range(0, len(items), size):
        yield items[i:i+size]
PYTHON
    filename = "index.py"
  }
}

data "archive_file" "verify_tags" {
  type        = "zip"
  output_path = "${path.module}/.dist/verify_tags.zip"
  source {
    content  = <<-PYTHON
import boto3
import json
from datetime import datetime, timezone

s3 = boto3.client("s3")

def lambda_handler(event, context):
    bucket = event["report_bucket"]
    inventory_key = event["inventory_key"]
    tag_key = event["tag_key"]
    tag_value = event["tag_value"]
    inventory = json.loads(s3.get_object(Bucket=bucket, Key=inventory_key)["Body"].read())
    grouped = {}
    for resource in inventory.get("resources", []):
        arn = resource.get("arn")
        region = resource.get("region")
        if arn and region:
            grouped.setdefault(region, []).append(arn)
    verification = []
    for region, arns in grouped.items():
        tagging = boto3.client("resourcegroupstaggingapi", region_name=region)
        for batch in chunks(arns, 100):
            response = tagging.get_resources(ResourceARNList=batch)
            found = {item["ResourceARN"]: {tag["Key"]: tag.get("Value", "") for tag in item.get("Tags", [])} for item in response.get("ResourceTagMappingList", [])}
            for arn in batch:
                tags = found.get(arn, {})
                verification.append({"arn": arn, "region": region, "verified": tags.get(tag_key) == tag_value, "observed_value": tags.get(tag_key), "observed_tags": tags})
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    verification_key = f"verification/apn-verification-{timestamp}.json"
    s3.put_object(Bucket=bucket, Key=verification_key, Body=json.dumps(verification, indent=2).encode("utf-8"), ContentType="application/json")
    return {"report_bucket": bucket, "inventory_key": inventory_key, "verification_key": verification_key, "checked": len(verification), "verified": sum(1 for r in verification if r["verified"]), "failed": sum(1 for r in verification if not r["verified"])}

def chunks(items, size):
    for i in range(0, len(items), size):
        yield items[i:i+size]
PYTHON
    filename = "index.py"
  }
}

# ── Lambda functions ──────────────────────────────────────────────────────────

resource "aws_lambda_function" "resolver" {
  function_name    = "prm-resource-explorer-view-resolver"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "index.lambda_handler"
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.resolver.output_path
  source_code_hash = data.archive_file.resolver.output_base64sha256
  environment {
    variables = {
      RESOURCE_EXPLORER_VIEW_NAME = var.resource_explorer_view_name
    }
  }
}

resource "aws_lambda_function" "inventory" {
  function_name    = "apn-attribution-inventory"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "index.lambda_handler"
  timeout          = 900
  memory_size      = 512
  filename         = data.archive_file.inventory.output_path
  source_code_hash = data.archive_file.inventory.output_base64sha256
  environment {
    variables = {
      REPORT_BUCKET   = aws_s3_bucket.report.id
      INVENTORY_QUERY = var.inventory_query
      TAG_KEY         = var.partner_central_id
      TAG_VALUE       = var.product_code
    }
  }
}

resource "aws_lambda_function" "apply_tags" {
  function_name    = "apn-attribution-apply-tags"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "index.lambda_handler"
  timeout          = 900
  memory_size      = 512
  filename         = data.archive_file.apply_tags.output_path
  source_code_hash = data.archive_file.apply_tags.output_base64sha256
}

resource "aws_lambda_function" "verify_tags" {
  function_name    = "apn-attribution-verify-tags"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "index.lambda_handler"
  timeout          = 900
  memory_size      = 512
  filename         = data.archive_file.verify_tags.output_path
  source_code_hash = data.archive_file.verify_tags.output_base64sha256
}

# ── Step Functions ────────────────────────────────────────────────────────────

resource "aws_sfn_state_machine" "main" {
  name     = "apn-attribution-one-time-workflow"
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "One-time PRM/APN inventory-driven attribution tagging workflow"
    StartAt = "ResolveResourceExplorerView"
    States = {
      ResolveResourceExplorerView = {
        Type     = "Task"
        Resource = aws_lambda_function.resolver.arn
        ResultPath = "$.resourceExplorerView"
        Retry = [{
          ErrorEquals = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException", "States.TaskFailed"]
          IntervalSeconds = 5
          MaxAttempts     = 4
          BackoffRate     = 2.0
        }]
        Next = "GenerateInventory"
      }
      GenerateInventory = {
        Type     = "Task"
        Resource = aws_lambda_function.inventory.arn
        Parameters = {
          "resource_explorer_view_arn.$" = "$.resourceExplorerView.resource_explorer_view_arn"
        }
        ResultPath = "$.inventory"
        Retry = [{
          ErrorEquals = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException", "States.TaskFailed"]
          IntervalSeconds = 10
          MaxAttempts     = 4
          BackoffRate     = 2.0
        }]
        Next = "HasResources"
      }
      HasResources = {
        Type = "Choice"
        Choices = [{
          Variable         = "$.inventory.resource_count"
          NumericGreaterThan = 0
          Next             = "ApplyTagsFromInventory"
        }]
        Default = "NoResources"
      }
      ApplyTagsFromInventory = {
        Type     = "Task"
        Resource = aws_lambda_function.apply_tags.arn
        Parameters = {
          "report_bucket.$"   = "$.inventory.report_bucket"
          "inventory_key.$"   = "$.inventory.inventory_key"
          "tag_key.$"         = "$.inventory.tag_key"
          "tag_value.$"       = "$.inventory.tag_value"
        }
        ResultPath = "$.apply"
        Retry = [{
          ErrorEquals = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 10
          MaxAttempts     = 3
          BackoffRate     = 2.0
        }]
        Next = "VerifyTags"
      }
      VerifyTags = {
        Type     = "Task"
        Resource = aws_lambda_function.verify_tags.arn
        Parameters = {
          "report_bucket.$"     = "$.inventory.report_bucket"
          "inventory_key.$"     = "$.inventory.inventory_key"
          "apply_results_key.$" = "$.apply.apply_results_key"
          "tag_key.$"           = "$.inventory.tag_key"
          "tag_value.$"         = "$.inventory.tag_value"
        }
        ResultPath = "$.verification"
        Retry = [{
          ErrorEquals = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 10
          MaxAttempts     = 3
          BackoffRate     = 2.0
        }]
        End = true
      }
      NoResources = {
        Type = "Succeed"
      }
    }
  })
}
