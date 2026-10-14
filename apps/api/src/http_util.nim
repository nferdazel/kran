## Utilitas respons HTTP (spec §13): JSON biasa & `application/problem+json`.

import std/json

import mummy

const
  ContentTypeJson* = "application/json"
  ContentTypeProblem* = "application/problem+json"

proc headersWithType*(contentType: string): HttpHeaders =
  result = emptyHttpHeaders()
  result["Content-Type"] = contentType

proc respondJson*(req: Request, status: int, body: JsonNode) =
  ## Satu tempat menulis respons JSON supaya header konsisten.
  req.respond(status, headersWithType(ContentTypeJson), $body)
