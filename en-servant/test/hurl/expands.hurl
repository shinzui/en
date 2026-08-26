POST {{base_url}}/v1/expand
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "consistency": {"mode": "fullyConsistent"},
  "object": {"objectType": "space", "objectId": "project-x"},
  "permission": "view",
  "context": {"values": {}},
  "limit": 10,
  "cursor": null
}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.root.objectType" == "space"
jsonpath "$.root.objectId" == "project-x"
jsonpath "$.permission" == "view"
jsonpath "$.children" exists
jsonpath "$.state.status" isString
jsonpath "$.checkedAt" isString
