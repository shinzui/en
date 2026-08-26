# Which spaces may alice view?
POST {{base_url}}/v1/lookup
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "minimizeLatency"},
  "subject": {"kind": "id", "objectType": "user", "objectId": "alice"},
  "permission": "view",
  "objectType": "space",
  "context": {"values": {}},
  "limit": 10,
  "cursor": null,
  "deadlineMillis": null
}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.objects" exists
jsonpath "$.state.status" isString
jsonpath "$.checkedAt" isString

# The dual lookup asks which users may view one space.
POST {{base_url}}/v1/lookup-subjects
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "minimizeLatency"},
  "object": {"objectType": "space", "objectId": "project-x"},
  "permission": "view",
  "subjectType": "user",
  "context": {"values": {}},
  "limit": 10,
  "cursor": null,
  "deadlineMillis": null
}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.subjects" exists
jsonpath "$.state.status" isString
jsonpath "$.checkedAt" isString
