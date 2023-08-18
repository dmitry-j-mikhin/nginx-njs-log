function request_headers(r) {
  return JSON.stringify(r.headersIn)
}

function response_headers(r) {
  return JSON.stringify(r.headersOut)
}

function request_body(r) {
    try {
      return JSON.stringify(require('fs').readFileSync(r.variables.request_body_file, 'utf8'))
    } catch(e) {
      return JSON.stringify("")
    }
}

function response_body(r) {
  return JSON.stringify(r.variables.response_body_raw)
}

function response_filter(r, data, flags) {
    r.variables.response_body_raw += data
    r.sendBuffer(data, flags)
}

export default {request_headers, response_headers, request_body, response_body, response_filter}
