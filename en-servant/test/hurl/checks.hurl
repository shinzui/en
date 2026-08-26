# A single check exercises the ordinary authenticated read path.
POST {{base_url}}/v1/check
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "minimizeLatency"},
  "context": {"values": {}},
  "subject": {"kind": "id", "objectType": "user", "objectId": "alice"},
  "permission": "view",
  "object": {"objectType": "space", "objectId": "project-x"}
}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.decision.result" isString
jsonpath "$.checkedAt" isString

# Batch check shares one consistency snapshot across all pairs.
POST {{base_url}}/v1/batch-check
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "minimizeLatency"},
  "context": {"values": {}},
  "pairs": [
    {
      "subject": {"kind": "id", "objectType": "user", "objectId": "alice"},
      "permission": "view",
      "object": {"objectType": "space", "objectId": "project-x"}
    }
  ]
}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.decisions" count == 1
jsonpath "$.decisions[0].result" isString
jsonpath "$.checkedAt" isString

# Servant rejects malformed bytes before the handler runs; the packaged server's
# error formatter must still return the fleet problem contract.
POST {{base_url}}/v1/check
Authorization: Bearer {{api_key}}
Content-Type: application/json
```
not json at all
```
HTTP 400
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.status" == 400
jsonpath "$.code" == "malformed_request_body"
jsonpath "$.retryable" == false

# A well-formed request can still name a relation absent from the active schema.
POST {{base_url}}/v1/check
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "minimizeLatency"},
  "context": {"values": {}},
  "subject": {"kind": "id", "objectType": "user", "objectId": "alice"},
  "permission": "not_a_permission",
  "object": {"objectType": "space", "objectId": "project-x"}
}
HTTP 400
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.status" == 400
jsonpath "$.code" == "unknown_relation"
jsonpath "$.retryable" == false

# This path exists for POST only; en deliberately models deletion as a POST subroute.
DELETE {{base_url}}/v1/relationships
Authorization: Bearer {{api_key}}
HTTP 405
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.status" == 405
jsonpath "$.code" == "method_not_allowed"
jsonpath "$.retryable" == false
