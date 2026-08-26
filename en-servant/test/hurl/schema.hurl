GET {{base_url}}/v1/schema
Authorization: Bearer {{api_key}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.source" contains "object space"
jsonpath "$.hash" startsWith "fnv1a64:"
jsonpath "$.origin" isString
jsonpath "$.loadedAt" isString
