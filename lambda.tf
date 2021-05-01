terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region = var.region
}

data aws_caller_identity current {}
 
locals {
  prefix = "bogo"
  app_dir = "apps"
  account_id          = data.aws_caller_identity.current.account_id
  ecr_repository_name = "${local.prefix}-demo-lambda-container"
  ecr_image_tag       = "latest"
}
 
resource aws_ecr_repository repo {
  name = local.ecr_repository_name
}

# The null_resource resource implements the standard resource lifecycle 
# but takes no further action.

# The triggers argument allows specifying an arbitrary set of values that, 
# when changed, will cause the resource to be replaced.

resource null_resource ecr_image {
  triggers = {
    python_file = md5(file("${path.module}/${local.app_dir}/app.py"))
    docker_file = md5(file("${path.module}/${local.app_dir}/Dockerfile"))
}
 
# The local-exec provisioner invokes a local executable after a resource is created. 
# This invokes a process on the machine running Terraform, not on the resource. 
# path.module: the filesystem path of the module where the expression is placed.

provisioner "local-exec" {
  command = <<EOF
           aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${local.account_id}.dkr.ecr.${var.region}.amazonaws.com
           #cd ${path.module}/lambdas/${local.prefix}_client
           cd ${path.module}/${local.app_dir}
           docker build -t ${aws_ecr_repository.repo.repository_url}:${local.ecr_image_tag} .
           docker push ${aws_ecr_repository.repo.repository_url}:${local.ecr_image_tag}
       EOF
 }
}

data aws_ecr_image lambda_image {
  depends_on = [
    null_resource.ecr_image
  ]
  repository_name = local.ecr_repository_name
  image_tag       = local.ecr_image_tag
}

resource aws_iam_role lambda {
  name = "${local.prefix}-lambda-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Action": "sts:AssumeRole",
          "Principal": {
              "Service": "lambda.amazonaws.com"
          },
          "Effect": "Allow"
      }
  ]
}
  EOF
}

data aws_iam_policy_document lambda {
  statement {
    actions = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
    ]
    effect = "Allow"
    resources = [ "*" ]
    sid = "CreateCloudWatchLogs"
  }
 
  statement {
    actions = [
        "codecommit:GitPull",
        "codecommit:GitPush",
        "codecommit:GitBranch",
        "codecommit:ListBranches",
        "codecommit:CreateCommit",
        "codecommit:GetCommit",
        "codecommit:GetCommitHistory",
        "codecommit:GetDifferences",
        "codecommit:GetReferences",
        "codecommit:BatchGetCommits",
        "codecommit:GetTree",
        "codecommit:GetObjectIdentifier",
        "codecommit:GetMergeCommit"
    ]
    effect = "Allow"
    resources = [ "*" ]
    sid = "CodeCommit"
  }
}

resource aws_iam_policy lambda {
  name = "${local.prefix}-lambda-policy"
  path = "/"
  policy = data.aws_iam_policy_document.lambda.json
}

resource aws_lambda_function bogo-lambda-function {
  depends_on = [
    null_resource.ecr_image
  ]
  function_name = "${local.prefix}-lambda"
  role = aws_iam_role.lambda.arn
  timeout = 300
  image_uri = "${aws_ecr_repository.repo.repository_url}@${data.aws_ecr_image.lambda_image.id}"
  package_type = "Image"
}

resource "aws_lambda_permission" "apigw" {
   statement_id  = "AllowAPIGatewayInvoke"
   action        = "lambda:InvokeFunction"
   function_name = aws_lambda_function.bogo-lambda-function.function_name
   principal     = "apigateway.amazonaws.com"

   # The "/*/*" portion grants access from any method on any resource
   # within the API Gateway REST API.
   source_arn = "${aws_api_gateway_rest_api.bogo-gateway.execution_arn}/*/*"
}

 
output "lambda_name" {
  value = aws_lambda_function.bogo-lambda-function.id
}


