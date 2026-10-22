# Bundle Update Log

## 2026-10-22
* **Addition**: Create the Improvement Request bundle on the `coordination.improvementRequests` profile from okf-profiles v0.12.0 and propose IR-1 from `mori://shinzui/nagare`: accept the API key in `X-En-Api-Key` beside `Authorization: Bearer`, because the Kubernetes API server's service proxy deletes the Authorization header after authenticating the caller, which keeps Nagare on a `kubectl port-forward` per En call.
