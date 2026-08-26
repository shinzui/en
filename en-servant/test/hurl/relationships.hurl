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
    },
    {
      "object": {"objectType": "space", "objectId": "hurl-write-flow-2"},
      "relation": "viewer",
      "subject": {"kind": "id", "objectType": "user", "objectId": "hurl-alice"},
      "caveat": null
    },
    {
      "object": {"objectType": "space", "objectId": "hurl-write-flow-3"},
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
    },
    {
      "object": {"objectType": "space", "objectId": "hurl-write-flow-2"},
      "relation": "viewer",
      "subject": {"kind": "id", "objectType": "user", "objectId": "hurl-alice"},
      "caveat": null
    },
    {
      "object": {"objectType": "space", "objectId": "hurl-write-flow-3"},
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

# Relay pagination lives in the query string even though the filter remains a POST body.
POST {{base_url}}/v1/relationships/query?first=2
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "atLeastAsFresh", "token": "{{write_token}}"},
  "filter": {"subjectType": "user", "subjectId": "hurl-alice"}
}
HTTP 200
[Captures]
relationship_cursor: jsonpath "$.pageInfo.endCursor"
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.edges" count == 2
jsonpath "$.pageInfo.hasNextPage" == true
jsonpath "$.pageInfo.hasPreviousPage" == false

# Continuations are snapshot-pinned by the opaque cursor; the body consistency is ignored.
POST {{base_url}}/v1/relationships/query?first=2&after={{relationship_cursor}}
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "minimizeLatency"},
  "filter": {"subjectType": "user", "subjectId": "hurl-alice"}
}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.edges" count == 1
jsonpath "$.pageInfo.hasNextPage" == false
jsonpath "$.pageInfo.hasPreviousPage" == true

POST {{base_url}}/v1/relationships/query?first=2&after=broken
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "minimizeLatency"},
  "filter": {"subjectType": "user", "subjectId": "hurl-alice"}
}
HTTP 400
[Asserts]
header "Content-Type" contains "application/json"
header "Content-Type" not contains "application/problem+json"
jsonpath "$.code" == "invalid_cursor"
jsonpath "$.retryable" == false

POST {{base_url}}/v1/relationships/query?first=-1
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "minimizeLatency"},
  "filter": {"subjectType": "user", "subjectId": "hurl-alice"}
}
HTTP 400
[Asserts]
header "Content-Type" contains "application/json"
header "Content-Type" not contains "application/problem+json"
jsonpath "$.code" == "negative_page_size"

POST {{base_url}}/v1/relationships/query?first=101
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "minimizeLatency"},
  "filter": {"subjectType": "user", "subjectId": "hurl-alice"}
}
HTTP 400
[Asserts]
header "Content-Type" contains "application/json"
header "Content-Type" not contains "application/problem+json"
jsonpath "$.code" == "page_size_too_large"

POST {{base_url}}/v1/relationships/query?first=2&last=2
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "minimizeLatency"},
  "filter": {"subjectType": "user", "subjectId": "hurl-alice"}
}
HTTP 400
[Asserts]
header "Content-Type" contains "application/json"
header "Content-Type" not contains "application/problem+json"
jsonpath "$.code" == "mixed_pagination_directions"
