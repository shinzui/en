GET {{base_url}}/v1/openapi.json
Authorization: Bearer {{api_key}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.openapi" startsWith "3.1"
jsonpath "$['paths']['/v1/check']['post']['operationId']" == "createV1Check"

# An unmatched route proves the packaged server installed the custom 404 formatter.
POST {{base_url}}/v1/no-such-path
Authorization: Bearer {{api_key}}
Content-Type: application/json
{}
HTTP 404
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.status" == 404
jsonpath "$.code" == "not_found"
jsonpath "$.retryable" == false
