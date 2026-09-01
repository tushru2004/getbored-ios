#!/bin/zsh
set -euo pipefail

readonly service_name='GetBored Debugging Workflows'
readonly username='tushru2004'
readonly region='eu-central-1'
readonly stack_name='getbored-debugging-workflows'
readonly script_dir="${0:A:h}"
tmp_js="$(mktemp /tmp/getbored-debugging-workflows.XXXXXX.js)"; tmp_curl="$(mktemp)"
trap 'rm -f "$tmp_js" "$tmp_curl"' EXIT

perl -0ne 'print $1 if m{<script>(.*?)</script>}s' "$script_dir/index.html" > "$tmp_js"
node --check "$tmp_js" >/dev/null
aws cloudformation validate-template --region "$region" --template-body "file://$script_dir/infra.yaml" >/dev/null

bucket="$(aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text)"
site_url="$(aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" --query 'Stacks[0].Outputs[?OutputKey==`SiteUrl`].OutputValue' --output text)"
password="$(security find-generic-password -s "$service_name" -a "$username" -w 2>/dev/null)"
chmod 600 "$tmp_curl"
printf 'user = "%s:%s"\n' "$username" "$password" > "$tmp_curl"
unset password

printf 'local HTML/JS syntax: pass\n'
printf 'CloudFormation template validation: pass\n'
printf 'S3 public access block: '
aws s3api get-public-access-block --region "$region" --bucket "$bucket" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text
printf 'direct S3 object status: '
curl --silent --output /dev/null --write-out '%{http_code}\n' "https://$bucket.s3.$region.amazonaws.com/index.html"
printf 'CloudFront unauthenticated status: '
curl --silent --output /dev/null --write-out '%{http_code}\n' "$site_url/"
printf 'CloudFront WWW-Authenticate: '
curl --silent --head "$site_url/" | tr -d '\r' | awk 'BEGIN {IGNORECASE=1} /^www-authenticate:/ {print $0}'
printf 'CloudFront authenticated status: '
curl --silent --config "$tmp_curl" --output /dev/null --write-out '%{http_code}\n' "$site_url/"
