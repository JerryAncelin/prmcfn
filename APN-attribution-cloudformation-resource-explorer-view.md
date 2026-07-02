# APN Attribution CloudFormation Deployment

## Purpose

This CloudFormation template deploys a one-time APN Partner Revenue Measurement attribution workflow.

The workflow discovers taggable AWS resources using AWS Resource Explorer, applies the required APN attribution tag, verifies the result, and stores inventory, execution, and verification evidence in an encrypted S3 bucket.

The important correction in this version is that the Resource Explorer view is now created as part of the CloudFormation stack. The stack no longer depends on a manually created view existing in the same Region as the deployment.

---

## Why the Resource Explorer View Is Included in the Stack

The inventory Lambda uses AWS Resource Explorer to search for resources that support tags.

Even when Resource Explorer indexing is globally available, the Lambda still needs a Resource Explorer view that exists in the Region where the stack is deployed and where the Lambda executes.

Previously, the Lambda depended on an existing view and attempted to discover one dynamically. That made the deployment fragile because the stack could fail or behave inconsistently if:

- no Resource Explorer view existed in the deployment Region;
- multiple views existed and the Lambda selected the wrong one;
- the default view was missing or not associated;
- the view did not expose tag properties;
- the Lambda executed in a Region different from the intended view.

This version fixes that by creating the view directly in CloudFormation and passing the view ARN explicitly to the Lambda.

---

## Deployed Resources

The template deploys the following core resources:

| Resource | Purpose |
|---|---|
| `AWS::ResourceExplorer2::View` | Creates the Resource Explorer view used for inventory discovery. |
| `AWS::ResourceExplorer2::DefaultViewAssociation` | Associates the created view as the default view in the deployment Region. |
| `AWS::S3::Bucket` | Stores inventory, apply results, and verification evidence. |
| `AWS::IAM::Role` for Lambda | Grants the Lambda functions permissions to discover resources, apply tags, verify tags, and write reports. |
| `InventoryLambda` | Searches Resource Explorer and writes the discovered resources to S3. |
| `ApplyTagsLambda` | Applies the APN attribution tag to discovered resources. |
| `VerifyTagsLambda` | Reads tags back and confirms whether the APN tag was applied. |
| `StepFunctionsRole` | Allows Step Functions to invoke the workflow Lambdas. |
| `StateMachine` | Orchestrates inventory, tagging, and verification. |

---

## Parameters

### `PartnerCentralID`

APN Partner Central ID.

This parameter is currently retained in the template for APN context and future compatibility. The active tagging logic in this version applies the `apn-id` tag using the `ProductCode` parameter as the value.

### `ProductCode`

The APN product code to apply as the value of the `apn-id` tag.

Example final tag applied by the workflow:

```text
apn-id=<ProductCode>
```

### `InventoryQuery`

The Resource Explorer query used by the inventory Lambda.

Default value:

```text
resourcetype.supports:tags
```

This default targets resources discovered by Resource Explorer that support tags.

---

## Resource Explorer View Fix

The template now includes the following Resource Explorer resources:

```yaml
APNAttributionResourceExplorerView:
  Type: AWS::ResourceExplorer2::View
  Properties:
    ViewName: apn-attribution-view
    IncludedProperties:
      - Name: tags
    Tags:
      - Key: Purpose
        Value: APN attribution inventory and tagging

APNAttributionDefaultViewAssociation:
  Type: AWS::ResourceExplorer2::DefaultViewAssociation
  Properties:
    ViewArn: !Ref APNAttributionResourceExplorerView
```

The created view ARN is then injected into the inventory Lambda as an environment variable:

```yaml
RESOURCE_EXPLORER_VIEW_ARN: !Ref APNAttributionResourceExplorerView
```

Inside the Lambda, the view ARN is read directly from the environment:

```python
def get_view_arn():
    return RESOURCE_EXPLORER_VIEW_ARN
```

This replaces the previous dynamic lookup logic that depended on `list_views()`.

---

## Tagging Logic

The inventory Lambda passes the tag key and value into the workflow output.

Current configuration:

```yaml
TAG_KEY: apn-id
TAG_VALUE: !Ref ProductCode
```

The apply Lambda receives those values from the Step Functions state and applies them using the Resource Groups Tagging API.

The verification Lambda then checks whether each discovered resource has the expected tag value.

---

## Workflow Execution

The Step Functions state machine runs three main stages.

### 1. Generate Inventory

The `InventoryLambda` searches Resource Explorer using the configured query and view ARN.

It writes the inventory to S3 under:

```text
inventory/apn-inventory-<timestamp>.json
```

The inventory output includes:

- AWS account ID;
- Resource ARN;
- Region;
- AWS service;
- Resource type;
- tag key;
- tag value;
- inventory query;
- generation timestamp.

### 2. Apply Tags

The `ApplyTagsLambda` groups resources by Region and applies the configured tag in batches.

It writes the tagging result to S3 under:

```text
apply-results/apn-apply-<timestamp>.json
```

The apply result includes:

- resource ARN;
- Region;
- tagging status;
- failure details, if any;
- applied tag key and value.

### 3. Verify Tags

The `VerifyTagsLambda` reads the current tags back using the Resource Groups Tagging API.

It writes the verification result to S3 under:

```text
verification/apn-verification-<timestamp>.json
```

The verification output includes:

- resource ARN;
- Region;
- whether the expected tag was found;
- observed tag value;
- full observed tag set.

---

## Practical Resource Exclusions

The inventory Lambda excludes a small set of resources that are commonly AWS-managed, default resources, or not safe to tag directly through this workflow.

Current exclusions include:

```python
EXCLUDED_RESOURCE_TYPES = {
    "cloudformation:stack",
    "athena:datacatalog",
}

EXCLUDED_ARN_CONTAINS = [
    ":datacatalog/AwsDataCatalog",
    ":user/default",
    ":acl/open-access",
    ":parametergroup/default.memorydb-",
]
```

CloudFormation resources are also excluded by service name.

This prevents the workflow from trying to tag resources that are usually managed through stack update semantics or AWS default service configuration.

---

## Deployment Steps

### 1. Deploy the CloudFormation Stack

Deploy the template in the AWS Region where the Lambda workflow should execute.

Provide the required parameters:

- `PartnerCentralID`
- `ProductCode`
- optionally override `InventoryQuery`

The default inventory query is usually sufficient for the APN attribution use case.

### 2. Confirm Stack Outputs

After deployment, check the CloudFormation outputs:

| Output | Description |
|---|---|
| `ResourceExplorerViewArn` | ARN of the Resource Explorer view created by the stack. |
| `ReportBucket` | S3 bucket where reports and evidence are stored. |
| `StateMachineArn` | Step Functions workflow to execute. |
| `InventoryLambda` | Inventory Lambda function name. |
| `ApplyTagsLambda` | Apply-tags Lambda function name. |
| `VerifyTagsLambda` | Verification Lambda function name. |

### 3. Start the Step Functions Workflow

Start the state machine manually from the AWS Console or through the AWS CLI.

No input payload is required for the standard execution path.

### 4. Review S3 Evidence

After execution, open the generated files in the report bucket:

```text
inventory/
apply-results/
verification/
```

These files provide the evidence trail for discovery, tag application, and verification.

---

## Important Operational Notes

### The Resource Explorer View Must Be Regional

The view must exist in the same Region where the stack and Lambda function execute.

This template now guarantees that by deploying the view as part of the same stack.

### Tags Persist After Stack Deletion

Tags applied to external resources by Lambda are not CloudFormation-managed resource properties.

Deleting the CloudFormation stack removes the workflow infrastructure, but it does not remove the `apn-id` tags that were applied to discovered resources.

### Resource Explorer Index Is Not Created by This Template

This version creates the Resource Explorer view, not the Resource Explorer index.

That is intentional. In many AWS environments, Resource Explorer is already enabled. Creating an index in CloudFormation can collide with an existing local or aggregator index.

The missing dependency in this workflow was the regional view, so the template now owns that dependency directly.

### Some AWS Internal or Default Resources May Be Discoverable but Not Taggable

Resource Explorer can discover resources that are AWS-managed, default service resources, or not safely taggable through the Resource Groups Tagging API.

The workflow handles this in two ways:

1. by excluding known problematic resource patterns during inventory;
2. by recording per-resource tagging failures in the apply result file.

This means discovery and taggability are related but not identical.

---

## Expected Final State

After a successful workflow execution:

- the stack owns the Resource Explorer view dependency;
- inventory is generated from the stack-created view;
- discovered taggable resources are tagged with `apn-id=<ProductCode>`;
- verification evidence is written to S3;
- failures are isolated per resource instead of failing the full workflow blindly;
- APN attribution evidence can be reviewed from the S3 report bucket.

---

## Recommended Validation Checklist

Before considering the run complete, confirm the following:

- CloudFormation stack deployed successfully.
- `ResourceExplorerViewArn` output exists.
- Step Functions execution completed successfully.
- Inventory file exists in S3.
- Apply-results file exists in S3.
- Verification file exists in S3.
- Verification count matches the expected resource scope.
- Failed resources, if any, are reviewed manually.
- Applied tag is visible on representative resources across multiple services and Regions.

---

## File Reference

Fixed CloudFormation template:

```text
apn-attribution-framework-fixed-cfn.yaml
```
