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
