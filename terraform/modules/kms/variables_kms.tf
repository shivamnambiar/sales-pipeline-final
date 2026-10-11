variable "name" {
  type    = string
  default = "sales-pipeline"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "region" {
  type        = string
  description = "AWS region, for region-scoped service principals (e.g. CloudWatch logs)"
}
