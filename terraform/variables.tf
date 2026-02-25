variable "region" {
    type = string
    default = "us-east-1"
}

variable "project" {
    type = string
    default = "fin-disclosures-demo"
}

variable "bucket_name" {
    type = string
}

variable "pii_hash_salt" {
    type = string
    sensitive = true
}