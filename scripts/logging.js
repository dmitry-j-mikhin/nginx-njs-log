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

var response_body_arr = new Array()
function response_body(r) {
  return JSON.stringify(response_body_arr.join(''))
}

function response_filter(r, data, flags) {
    response_body_arr.push(data.toString())
    r.sendBuffer(data, flags)
}

export default {request_headers, response_headers, request_body, response_body, response_filter}
