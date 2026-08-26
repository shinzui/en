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

# The idempotent mutating flow is added in Milestone 4 below this block.
