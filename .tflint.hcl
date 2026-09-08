# TFLint configuration — used by the `lint` job in terraform.yaml and by the
# `terraform_tflint` pre-commit hook, from this one file, so a clean local
# run means a clean CI run. Kept in sync with Terraform-platform's .tflint.hcl.
#
# The tflint binary version is pinned in terraform.yaml (`tflint_version:`).
# The aws ruleset is pinned below by exact `version` (ranges are rejected)
# plus `signature = "attestation"`, which makes `tflint --init` verify the
# plugin's GitHub build-provenance attestation before installing it — the
# same provenance mechanism this repo already uses for tfplan artifacts.
# TFLint has no lock file.

config {
  # organization/ and platform/ are standalone roots; nothing here calls a
  # local child module, so there is nothing to descend into. Keeps tflint
  # from needing `terraform init`.
  call_module_type = "none"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled   = true
  version   = "0.48.0" # re-run `tflint --init` on change
  source    = "github.com/terraform-linters/tflint-ruleset-aws"
  signature = "attestation"
}
