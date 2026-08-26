# A failed precondition is safe: the store rolls the whole write transaction back.
POST {{base_url}}/v1/relationships
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "tuples": [],
  "preconditions": [
    {
      "kind": "mustExist",
      "filter": {
        "objectType": "space",
        "objectId": "hurl-precondition-missing",
        "relation": "viewer",
        "subjectType": "user",
        "subjectId": "nobody",
        "subjectRelation": {"match": "none"}
      }
    }
  ]
}
HTTP 412
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.status" == 412
jsonpath "$.code" == "write_precondition_failed"
jsonpath "$.retryable" == false

# The idempotent mutating flow follows this safe failure case.

# Delete first so every run starts from a known state.
POST {{base_url}}/v1/relationships/delete
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "tuples": [
    {
      "object": {"objectType": "space", "objectId": "hurl-write-flow"},
      "relation": "viewer",
      "subject": {"kind": "id", "objectType": "user", "objectId": "hurl-alice"},
      "caveat": null
    }
  ]
}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.token" isString

# Write the relationship and retain the consistency token returned by the store.
POST {{base_url}}/v1/relationships
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "tuples": [
    {
      "object": {"objectType": "space", "objectId": "hurl-write-flow"},
      "relation": "viewer",
      "subject": {"kind": "id", "objectType": "user", "objectId": "hurl-alice"},
      "caveat": null
    }
  ]
}
HTTP 200
[Captures]
write_token: jsonpath "$.token"
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.token" isString

# A public read at the write's token must observe the relationship immediately.
POST {{base_url}}/v1/check
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "atLeastAsFresh", "token": "{{write_token}}"},
  "context": {"values": {}},
  "subject": {"kind": "id", "objectType": "user", "objectId": "hurl-alice"},
  "permission": "view",
  "object": {"objectType": "space", "objectId": "hurl-write-flow"}
}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.decision.result" == "allowed"
jsonpath "$.checkedAt" isString
