#!/bin/zsh
set -euo pipefail

readonly service_name='GetBored Debugging Workflows'
readonly username='tushru2004'
readonly region='eu-central-1'
readonly stack_name='getbored-debugging-workflows'
readonly script_dir="${0:A:h}"

if ! password="$(security find-generic-password -s "$service_name" -a "$username" -w 2>/dev/null)"; then
  password="$(openssl rand -base64 48)"
  security add-generic-password -U -s "$service_name" -a "$username" -w "$password" >/dev/null
fi
credential="$(printf '%s' "$username:$password" | base64 | tr -d '\n')"
unset password

aws cloudformation deploy --region "$region" --stack-name "$stack_name" --template-file "$script_dir/infra.yaml" --capabilities CAPABILITY_NAMED_IAM --parameter-overrides BasicAuthCredential="$credential" --no-fail-on-empty-changeset
unset credential

bucket="$(aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text)"
aws s3 sync "$script_dir/" "s3://$bucket/" --exclude 'infra.yaml' --exclude 'deploy.sh' --exclude 'validate.sh' --delete --sse AES256
distribution_id="$(aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" --query 'Stacks[0].Outputs[?OutputKey==`DistributionId`].OutputValue' --output text)"
aws cloudfront create-invalidation --distribution-id "$distribution_id" --paths '/*' --output text >/dev/null
aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
