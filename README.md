# AWS PRM / APN Attribution Tagging Framework

This repository provides a one-time CloudFormation-based helper for AWS Partners who need to discover AWS resources and apply AWS Partner Revenue Measurement / APN attribution tags at scale.

The workflow discovers taggable AWS resources using AWS Resource Explorer, applies the required attribution tag, and stores inventory, apply results, and verification evidence in S3.

## What this solution does

The CloudFormation template deploys a Step Functions workflow with four Lambda functions:

1. **Resolve Resource Explorer View**
   - Checks whether a Resource Explorer view already exists in the deployment Region.
   - Reuses the existing named view if found.
   - Creates the view if it does not exist.
   - Returns the Resource Explorer view ARN to the workflow.

2. **Generate Inventory**
   - Uses the resolved Resource Explorer view ARN.
   - Searches for taggable resources using the configured Resource Explorer query.
   - Excludes known AWS-managed/default resources that should not be tagged directly.
   - Writes the discovered inventory to S3.

3. **Apply Tags**
   - Reads the inventory from S3.
   - Groups resources by Region.
   - Applies the PRM/APN attribution tag using the Resource Groups Tagging API.
   - Writes apply results to S3.

4. **Verify Tags**
   - Reads the original inventory.
   - Checks whether the expected tag is present on each resource.
   - Writes verification evidence to S3.

---

## Tagging model

For this implementation, the PRM attribution tag is built from two CloudFormation parameters:

| Parameter | Purpose |
|---|---|
| `PartnerCentralID` | Used as the tag key |
| `ProductCode` | Used as the tag value |

The resulting tag applied to resources is:

```text
<PartnerCentralID> = <ProductCode>
```

Example:

```text
1234567 = my-product-code
```

---

## Why the Resource Explorer view is resolved by Lambda

Earlier versions attempted to create a Resource Explorer view directly in CloudFormation and associate it as the default view. That approach caused two practical issues in real AWS accounts:

- `AWS::ResourceExplorer2::View` does not accept the usual CloudFormation tag array syntax for `Tags`.
- `AWS::ResourceExplorer2::DefaultViewAssociation` fails when the Region already has a default Resource Explorer view associated.

The current version avoids both issues.

Instead of relying on `DefaultViewAssociation`, the workflow starts with a resolver Lambda. This Lambda checks for a named Resource Explorer view in the Region where the stack is deployed, creates it if missing, and passes the exact view ARN into the inventory Lambda.

This makes the deployment more resilient in existing AWS accounts where Resource Explorer may already be partially configured.

---

## Architecture

```text
CloudFormation Stack
      |
      v
Step Functions State Machine
      |
      +--> ResolveResourceExplorerView Lambda
      |        |
      |        +--> Reuse or create Resource Explorer view
      |        +--> Return resource_explorer_view_arn
      |
      +--> GenerateInventory Lambda
      |        |
      |        +--> Search resources through Resource Explorer
      |        +--> Store inventory JSON in S3
      |
      +--> ApplyTags Lambda
      |        |
      |        +--> Apply <PartnerCentralID>=<ProductCode>
      |        +--> Store apply results in S3
      |
      +--> VerifyTags Lambda
               |
               +--> Verify expected tag value
               +--> Store verification evidence in S3
```

---

## Deployed AWS resources

The template deploys:

- S3 bucket for reports and evidence
- IAM role for Lambda functions
- IAM role for Step Functions
- Lambda function: `prm-resource-explorer-view-resolver`
- Lambda function: `apn-attribution-inventory`
- Lambda function: `apn-attribution-apply-tags`
- Lambda function: `apn-attribution-verify-tags`
- Step Functions state machine: `apn-attribution-one-time-workflow`

---

## CloudFormation parameters

| Parameter | Default | Description |
|---|---:|---|
| `PartnerCentralID` | None | Partner Central ID used as the PRM attribution tag key. |
| `ProductCode` | None | Product code used as the PRM attribution tag value. |
| `InventoryQuery` | `resourcetype.supports:tags` | Resource Explorer query used to discover resources. |
| `ResourceExplorerViewName` | `prm-attribution-view` | Resource Explorer view name to reuse or create in the stack Region. |

---

## Deployment

Deploy the CloudFormation template in the AWS account and Region where you want to run the tagging workflow.

Example using AWS CLI:

```bash
aws cloudformation deploy \
  --template-file prmcfn-with-resource-explorer-resolver.yaml \
  --stack-name prm-attribution-tagging \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      PartnerCentralID="YOUR_PARTNER_CENTRAL_ID" \
      ProductCode="YOUR_PRODUCT_CODE"
```

Optional parameter override for the Resource Explorer query:

```bash
aws cloudformation deploy \
  --template-file prmcfn-with-resource-explorer-resolver.yaml \
  --stack-name prm-attribution-tagging \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      PartnerCentralID="YOUR_PARTNER_CENTRAL_ID" \
      ProductCode="YOUR_PRODUCT_CODE" \
      InventoryQuery="resourcetype.supports:tags" \
      ResourceExplorerViewName="prm-attribution-view"
```

---

## Running the workflow

After deployment, start the Step Functions state machine from the AWS Console or CLI.

CLI example:

```bash
aws stepfunctions start-execution \
  --state-machine-arn "STATE_MACHINE_ARN_FROM_CLOUDFORMATION_OUTPUT"
```

The state machine input can be empty. The workflow resolves the Resource Explorer view and passes the view ARN internally between states.

---

## Evidence produced in S3

The report bucket stores three categories of output:

```text
inventory/
apply-results/
verification/
```

### Inventory output

Contains discovered resources and the tag expected to be applied.

Example path:

```text
inventory/apn-inventory-YYYYMMDDTHHMMSSZ.json
```

### Apply results

Contains tagging results and failed resources returned by the Resource Groups Tagging API.

Example path:

```text
apply-results/apn-apply-YYYYMMDDTHHMMSSZ.json
```

### Verification output

Contains the final observed tags and whether the expected tag value was found.

Example path:

```text
verification/apn-verification-YYYYMMDDTHHMMSSZ.json
```

---

## Retry and resilience behavior

The solution includes retry logic in two layers.

### Step Functions retry

Each Lambda task has Step Functions retry rules for Lambda service errors, SDK client errors, throttling, and task failures.

### Lambda-level retry

The Resource Explorer resolver and inventory Lambda also include retry logic for transient Resource Explorer issues such as throttling, delayed view readiness, temporary `ResourceNotFoundException`, and validation timing issues.

This is useful because Resource Explorer views may take a short amount of time to become readable/searchable immediately after creation.

---

## Resource exclusions

The inventory Lambda excludes some practical resource types observed during pilot execution, including:

- CloudFormation stacks
- Athena default data catalog resources
- AWS-managed/default MemoryDB resources
- AWS-managed/default OpenSearch or ACL-style resources where direct tagging is not appropriate

These exclusions are implemented to avoid applying tags to resources that are AWS-managed, default service resources, or better handled through service-specific lifecycle mechanisms.

---

## Important operational notes

- Run this first in a non-production account.
- Review IAM permissions before production use.
- Some AWS resources discovered by Resource Explorer may not support tagging through the generic Resource Groups Tagging API.
- Some resources may require service-specific tagging APIs.
- Some AWS-managed resources may be discoverable but should not be tagged directly.
- Stack deletion does not remove tags that were already applied to resources.
- The Resource Explorer resolver intentionally avoids changing the account/Region default Resource Explorer view association.

---

## Cleanup behavior

Deleting the CloudFormation stack removes the deployed automation resources such as Lambdas, IAM roles, Step Functions state machine, and the report bucket according to CloudFormation behavior.

Tags already applied to AWS resources are not removed by deleting this stack.

---

## Repository scope

This project contains a generic AWS automation pattern using public AWS services:

- AWS CloudFormation
- AWS Resource Explorer
- AWS Lambda
- AWS Step Functions
- AWS IAM
- Amazon S3
- Resource Groups Tagging API

It does not contain customer data, proprietary business logic, credentials, or internal documentation.

---

## Disclaimer

This project is provided as-is as a community helper for AWS Partners. Validate the template, permissions, query scope, and tagging behavior against your own AWS environment and compliance requirements before use.
