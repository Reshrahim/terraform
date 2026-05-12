terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

variable "context" {
  description = "Radius-provided context for the recipe"
  type        = any
}

variable "region" {
  description = "AWS region for provisioned resources"
  type        = string
  default     = "us-west-2"
}

locals {
  name           = var.context.resource.name
  namespace      = var.context.runtime.kubernetes.namespace
  application    = var.context.resource.properties.application
  environment    = var.context.resource.properties.environment
  prompt         = var.context.resource.properties.prompt
  model          = try(var.context.resource.properties.model, "anthropic.claude-3-5-sonnet-20241022-v2:0")
  knowledge_base = "${local.name}-kb"
  agent_image    = "ghcr.io/reshrahim/agent-runtime:1.0"

  # Postgres connection from Radius connections
  postgres_host     = try(var.context.resource.connections.postgres.properties.host, "")
  postgres_port     = try(var.context.resource.connections.postgres.properties.port, "")
  postgres_database = try(var.context.resource.connections.postgres.properties.database, "")
  postgres_user     = try(var.context.resource.connections.postgres.properties.user, "")
  postgres_password = try(var.context.resource.connections.postgres.properties.password, "")

  # Blob storage connection from Radius connections
  storage_bucket    = try(var.context.resource.connections.blobstorage.properties.accountName, "")
  storage_container = try(var.context.resource.connections.blobstorage.properties.container, "documents")

  tags = {
    "radius-app"           = local.name
    "radius-resource-type" = "Radius.AI/agents"
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

# ── CloudWatch Log Group ────────────────────────────────────

resource "aws_cloudwatch_log_group" "agent" {
  name              = "radius-${local.name}"
  retention_in_days = 30
  tags              = local.tags
}

# ── OpenSearch Serverless ───────────────────────────────────

resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.name}-enc"
  type = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.name}-${random_id.suffix.hex}"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.name}-net"
  type = "network"
  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.name}-${random_id.suffix.hex}"]
    }, {
      ResourceType = "dashboard"
      Resource     = ["collection/${local.name}-${random_id.suffix.hex}"]
    }]
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_collection" "search" {
  name = "${local.name}-${random_id.suffix.hex}"
  type = "SEARCH"
  tags = local.tags

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
  ]
}

# Data access policy for the Lambda and agent runtime
data "aws_caller_identity" "current" {}

resource "aws_opensearchserverless_access_policy" "data" {
  name = "${local.name}-data"
  type = "data"
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "index"
        Resource     = ["index/${local.name}-${random_id.suffix.hex}/*"]
        Permission   = ["aoss:CreateIndex", "aoss:UpdateIndex", "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"]
      },
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.name}-${random_id.suffix.hex}"]
        Permission   = ["aoss:CreateCollectionItems", "aoss:DescribeCollectionItems", "aoss:UpdateCollectionItems"]
      }
    ]
    Principal = [
      data.aws_caller_identity.current.arn,
      aws_iam_role.lambda_role.arn,
      aws_iam_role.agent_pod_role.arn,
    ]
  }])
}

# ── IAM Role for Lambda (S3→OpenSearch ingestion) ───────────

resource "aws_iam_role" "lambda_role" {
  name = "${local.name}-lambda-${random_id.suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda-permissions"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${local.storage_bucket}", "arn:aws:s3:::${local.storage_bucket}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["aoss:APIAccessAll"]
        Resource = [aws_opensearchserverless_collection.search.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
      }
    ]
  })
}

# ── Lambda: S3 → OpenSearch Ingestion ───────────────────────

data "archive_file" "indexer" {
  type        = "zip"
  output_path = "${path.module}/indexer.zip"

  source {
    content  = <<-PYTHON
import boto3
import json
import os
import urllib.request
import urllib.parse

from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials

COLLECTION_ENDPOINT = os.environ["OPENSEARCH_ENDPOINT"]
INDEX_NAME = os.environ["INDEX_NAME"]

def signed_request(method, url, body=None):
    """Make a SigV4-signed request to OpenSearch Serverless."""
    session = boto3.Session()
    creds = session.get_credentials().get_frozen_credentials()
    headers = {"Content-Type": "application/json"}
    req = AWSRequest(method=method, url=url, data=body, headers=headers)
    SigV4Auth(creds, "aoss", os.environ.get("AWS_REGION", "us-west-2")).add_auth(req)
    http_req = urllib.request.Request(
        url=req.url,
        data=req.body.encode("utf-8") if req.body else None,
        headers=dict(req.headers),
        method=method,
    )
    try:
        with urllib.request.urlopen(http_req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}")
        raise

def ensure_index():
    """Create the search index if it doesn't exist."""
    url = f"{COLLECTION_ENDPOINT}/{INDEX_NAME}"
    mapping = {
        "mappings": {
            "properties": {
                "content": {"type": "text"},
                "title":   {"type": "text"},
                "source":  {"type": "keyword"},
            }
        }
    }
    try:
        signed_request("PUT", url, json.dumps(mapping))
        print(f"Created index {INDEX_NAME}")
    except Exception as e:
        if "resource_already_exists" in str(e).lower() or "already exists" in str(e).lower():
            print(f"Index {INDEX_NAME} already exists")
        else:
            raise

def handler(event, context):
    s3 = boto3.client("s3")
    ensure_index()

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        print(f"Processing s3://{bucket}/{key}")

        obj = s3.get_object(Bucket=bucket, Key=key)
        content = obj["Body"].read().decode("utf-8", errors="replace")
        title = key.rsplit("/", 1)[-1]

        doc_id = urllib.parse.quote(key, safe="")
        doc = {"content": content, "title": title, "source": f"s3://{bucket}/{key}"}

        url = f"{COLLECTION_ENDPOINT}/{INDEX_NAME}/_doc/{doc_id}"
        signed_request("PUT", url, json.dumps(doc))
        print(f"Indexed {key}")

    return {"statusCode": 200}
PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "indexer" {
  function_name    = "${local.name}-indexer-${random_id.suffix.hex}"
  handler          = "index.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_role.arn
  filename         = data.archive_file.indexer.output_path
  source_code_hash = data.archive_file.indexer.output_base64sha256
  timeout          = 300
  memory_size      = 256

  environment {
    variables = {
      OPENSEARCH_ENDPOINT = aws_opensearchserverless_collection.search.collection_endpoint
      INDEX_NAME          = local.knowledge_base
    }
  }

  tags = local.tags
}

# S3 event trigger for the Lambda
resource "aws_lambda_permission" "s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.indexer.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = "arn:aws:s3:::${local.storage_bucket}"
}

resource "aws_s3_bucket_notification" "indexer_trigger" {
  bucket = local.storage_bucket

  lambda_function {
    lambda_function_arn = aws_lambda_function.indexer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "${local.storage_container}/"
  }

  depends_on = [aws_lambda_permission.s3]
}

# ── IAM Role for Agent Pod (IRSA) ──────────────────────────

resource "aws_iam_role" "agent_pod_role" {
  name = "${local.name}-pod-${random_id.suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.eks.${var.region}.amazonaws.com"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "agent_pod_policy" {
  name = "agent-permissions"
  role = aws_iam_role.agent_pod_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["aoss:APIAccessAll"]
        Resource = [aws_opensearchserverless_collection.search.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${local.storage_bucket}", "arn:aws:s3:::${local.storage_bucket}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["*"]
      }
    ]
  })
}

# ── Agent Runtime — Kubernetes Deployment ───────────────────

resource "kubernetes_deployment" "agent_runtime" {
  metadata {
    name      = "agent-runtime"
    namespace = local.namespace
    labels = {
      app                    = "agent-runtime"
      "radius-resource-type" = "Radius.AI-agents"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "agent-runtime"
      }
    }

    template {
      metadata {
        labels = {
          app = "agent-runtime"
        }
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.agent_pod_role.arn
        }
      }

      spec {
        service_account_name = "agent-runtime"

        container {
          name              = "agent-runtime"
          image             = local.agent_image
          image_pull_policy = "Always"

          port {
            container_port = 8000
          }

          env {
            name  = "CLOUD_PROVIDER"
            value = "aws"
          }
          env {
            name  = "AGENT_PROMPT"
            value = local.prompt
          }
          env {
            name  = "CONNECTION_MODEL_DEPLOYMENT"
            value = local.model
          }
          env {
            name  = "CONNECTION_MODEL_REGION"
            value = var.region
          }
          env {
            name  = "CONNECTION_SEARCH_ENDPOINT"
            value = aws_opensearchserverless_collection.search.collection_endpoint
          }
          env {
            name  = "CONNECTION_SEARCH_INDEX"
            value = local.knowledge_base
          }
          env {
            name  = "CONNECTION_STORAGE_BUCKET"
            value = local.storage_bucket
          }
          env {
            name  = "CONNECTION_POSTGRES_HOST"
            value = local.postgres_host
          }
          env {
            name  = "CONNECTION_POSTGRES_PORT"
            value = tostring(local.postgres_port)
          }
          env {
            name  = "CONNECTION_POSTGRES_DATABASE"
            value = local.postgres_database
          }
          env {
            name  = "CONNECTION_POSTGRES_USER"
            value = local.postgres_user
          }
          env {
            name  = "CONNECTION_POSTGRES_PASSWORD"
            value = local.postgres_password
          }
          env {
            name  = "AWS_REGION"
            value = var.region
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "agent_runtime" {
  metadata {
    name      = "agent-runtime"
    namespace = local.namespace
  }

  spec {
    selector = {
      app = "agent-runtime"
    }

    port {
      port        = 8000
      target_port = 8000
    }
  }
}

resource "kubernetes_service_account" "agent_runtime" {
  metadata {
    name      = "agent-runtime"
    namespace = local.namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.agent_pod_role.arn
    }
  }
}

# ── Output ──────────────────────────────────────────────────

output "result" {
  value = {
    values = {
      agentEndpoint = "http://agent-runtime:8000"
    }
    resources = []
  }
}
