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
      return null
    }
}

function response_filter(r, data, flags) {
    r.variables.response_body_njs += data
    if (flags.last) {
      r.variables.response_body_njs = JSON.stringify(r.variables.response_body_njs)
    }
    r.sendBuffer(data, flags)
}

export default {request_headers, response_headers, request_body, response_filter}
