#!/bin/bash
set -e

awslocal s3 mb s3://sales-raw

awslocal sqs create-queue --queue-name sales-jobs-dlq

DLQ_ARN=$(awslocal sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/sales-jobs-dlq \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

awslocal sqs create-queue --queue-name sales-jobs \
  --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}"

echo "init complete: bucket sales-raw, queue sales-jobs, dlq sales-jobs-dlq (maxReceiveCount=3)"
