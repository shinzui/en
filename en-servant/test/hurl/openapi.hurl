GET {{base_url}}/v1/openapi.json
Authorization: Bearer {{api_key}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.openapi" startsWith "3.1"
jsonpath "$['paths']['/v1/check']['post']['operationId']" == "createV1Check"
