# Operational probes stay public even when API-key authentication is enabled.
GET {{base_url}}/health/live
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.status" == "ok"

# An authenticated read without a credential is rejected and challenges for Bearer auth.
GET {{base_url}}/v1/schema
HTTP 401
[Asserts]
header "Content-Type" contains "application/problem+json"
header "WWW-Authenticate" == "Bearer"
jsonpath "$.status" == 401
jsonpath "$.code" == "unauthenticated"
jsonpath "$.retryable" == false

# An unknown credential is indistinguishable from a missing one.
GET {{base_url}}/v1/schema
Authorization: Bearer {{invalid_api_key}}
HTTP 401
[Asserts]
header "Content-Type" contains "application/problem+json"
header "WWW-Authenticate" == "Bearer"
jsonpath "$.status" == 401
jsonpath "$.code" == "unauthenticated"
jsonpath "$.retryable" == false

# A configured read-write credential crosses the perimeter successfully.
GET {{base_url}}/v1/schema
Authorization: Bearer {{api_key}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.hash" startsWith "fnv1a64:"

# A read-only credential authenticates but cannot mutate authorization state.
POST {{base_url}}/v1/relationships
Authorization: Bearer {{read_only_api_key}}
Content-Type: application/json
{
  "tuples": []
}
HTTP 403
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.status" == 403
jsonpath "$.code" == "permission_denied"
jsonpath "$.retryable" == false
