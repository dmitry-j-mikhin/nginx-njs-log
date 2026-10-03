/*
 * Full request/response (headers + body) logging for nginx with njs.
 *
 * The whole access log record is assembled here and serialized with
 * JSON.stringify(), so client-controlled values (Host, User-Agent, URI,
 * headers, bodies) can never break or forge the JSON written to the log.
 *
 * Configuration contract, see nginx/templates/njs-log.conf.template:
 *
 *   js_var $njs_log_body_max_size 64k;      bytes kept per body, 0 disables
 *   js_var $njs_log_redact off;             on: mask the headers below
 *   js_var $njs_log_redact_headers "...";   header names, "*" matches any part
 *   js_var $njs_log_redact_value "...";     text logged instead of their values
 *   js_set $njs_log_record logging.record;
 *   log_format njs_json escape=none $njs_log_record;
 *
 *   location / {
 *       js_access      logging.capture_request_body;
 *       js_body_filter logging.capture_response_body buffer_type=buffer;
 *       ...
 *   }
 *
 * Bodies that are valid UTF-8 are logged as text, anything else as base64
 * with a "<field>_base64": true marker.  Bodies cut at the size limit get a
 * "<field>_truncated": true marker.
 *
 * Works with both the njs and the QuickJS engine (js_engine njs|qjs).
 */

const DEFAULT_BODY_MAX_SIZE = 64 * 1024;
const DEFAULT_REDACT_HEADERS = 'authorization proxy-authorization cookie set-cookie';
const DEFAULT_REDACT_VALUE = '[redacted]';

/* nginx variables copied into every record, in output order. */
const VARIABLES = [
    ['msec', asNumber],
    ['time_iso8601', asString],
    ['request_id', asString],
    ['request_time', asNumber],
    ['body_bytes_sent', asNumber],
    ['bytes_sent', asNumber],
    ['request_length', asNumber],
    ['http_host', asString],
    ['http_user_agent', asString],
    ['remote_addr', asString],
    ['request_method', asString],
    ['request_uri', asString],
    ['status', asNumber],
    ['upstream_addr', asString],
];

const utf8 = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true});

/*
 * Bodies captured for the request being processed, shared by the js_access,
 * js_body_filter and js_set handlers.  The njs engine gives every request
 * a fresh VM, but QuickJS reuses contexts between requests
 * (js_context_reuse), so the owner is checked on every call and the state
 * is dropped once the record has been built.
 */
let current = null;

function asNumber(value) {
    const n = Number(value);
    return value === undefined || value === '' || isNaN(n) ? null : n;
}

function asString(value) {
    return value === undefined ? null : String(value);
}

function bodyMaxSize(r) {
    const m = /^\s*(\d+)\s*([kKmM]?)\s*$/.exec(r.variables.njs_log_body_max_size || '');

    if (m === null) {
        return DEFAULT_BODY_MAX_SIZE;
    }

    const unit = m[2].toLowerCase();

    return Number(m[1]) * (unit === 'k' ? 1024 : unit === 'm' ? 1024 * 1024 : 1);
}

function isOn(value) {
    return /^\s*(on|yes|true|1)\s*$/i.test(value || '');
}

/*
 * Header masking settings, or null when masking is off.  Header names are
 * matched case-insensitively, "*" matches any sequence of characters.
 */
function redaction(r) {
    if (!isOn(r.variables.njs_log_redact)) {
        return null;
    }

    let names = r.variables.njs_log_redact_headers;
    let value = r.variables.njs_log_redact_value;

    if (names === undefined) {
        names = DEFAULT_REDACT_HEADERS;
    }

    if (value === undefined) {
        value = DEFAULT_REDACT_VALUE;
    }

    const patterns = names.split(/[\s,]+/).filter(function(name) {
        return name !== '';

    }).map(function(name) {
        return name.replace(/[.+?^$|()[\]{}\\]/g, '\\$&').replace(/\*/g, '.*');
    });

    if (patterns.length === 0) {
        return null;
    }

    return {names: new RegExp(`^(?:${patterns.join('|')})$`, 'i'), value: value};
}

function state(r) {
    if (current === null || current.r !== r) {
        current = {
            r: r,
            limit: bodyMaxSize(r),
            request: undefined,
            chunks: [],
            size: 0,
            truncated: false,
        };
    }

    return current;
}

/* Copies the first "limit" bytes, so that the source can be released. */
function head(data, limit) {
    return {
        data: Buffer.from(data.length > limit ? data.slice(0, limit) : data),
        truncated: data.length > limit,
    };
}

/*
 * js_access handler: reads the whole request body before it is passed to
 * the upstream (from memory or from the client_body_temp_path file) and
 * keeps its head.  nginx closes the temporary file once the body has been
 * sent upstream, so in the log phase large bodies are no longer readable.
 */
async function capture_request_body(r) {
    const s = state(r);

    if (s.limit === 0) {
        return;
    }

    try {
        const body = await r.readRequestArrayBuffer();

        s.request = body && body.byteLength ? head(Buffer.from(body), s.limit) : null;

    } catch (e) {
        r.warn(`njs-log: request body capture failed: ${e}`);
    }
}

/* js_body_filter handler with buffer_type=buffer. */
function capture_response_body(r, data, flags) {
    try {
        const s = state(r);
        const room = s.limit - s.size;

        if (s.limit > 0 && data.length > 0) {
            if (room > 0) {
                /* copy: data may point to an nginx buffer that gets reused */
                const chunk = head(data, room).data;

                s.chunks.push(chunk);
                s.size += chunk.length;
            }

            if (data.length > room) {
                s.truncated = true;
            }
        }

    } catch (e) {
        r.warn(`njs-log: response body capture failed: ${e}`);
    }

    r.sendBuffer(data, flags);
}

/*
 * Request body for locations without js_access: only a body that is still
 * in memory can be read in the log phase.
 */
function requestBodyInMemory(r, limit) {
    if (r.variables.request_body_file) {
        return {data: Buffer.alloc(0), truncated: true};
    }

    const body = r.requestBuffer;

    return body ? head(body, limit) : null;
}

/* Drops a multi-byte UTF-8 sequence cut in half by truncation. */
function trimIncompleteUtf8(data) {
    const len = data.length;

    for (let i = len - 1; i >= 0 && i >= len - 4; i--) {
        const b = data[i];

        if ((b & 0xc0) === 0x80) {
            continue;
        }

        const need = b >= 0xf0 ? 4 : b >= 0xe0 ? 3 : b >= 0xc0 ? 2 : 1;

        return i + need > len ? data.slice(0, i) : data;
    }

    return data;
}

function putBody(rec, name, body) {
    rec[name] = '';

    if (body === null) {
        return;
    }

    const data = body.data;

    if (data.length) {
        try {
            rec[name] = utf8.decode(body.truncated ? trimIncompleteUtf8(data) : data);

        } catch (e) {
            rec[name] = data.toString('base64');
            rec[name + '_base64'] = true;
        }
    }

    if (body.truncated) {
        rec[name + '_truncated'] = true;
    }
}

function copyHeaders(headers, redact) {
    const out = {};

    Object.keys(headers).forEach(function(name) {
        out[name] = redact !== null && redact.names.test(name) ? redact.value : headers[name];
    });

    return out;
}

/* js_set handler: the complete access log record as a JSON string. */
function record(r) {
    const rec = {source: 'nginx'};
    const s = current !== null && current.r === r ? current : null;

    current = null;

    try {
        const limit = bodyMaxSize(r);
        const redact = redaction(r);

        VARIABLES.forEach(function(v) {
            rec[v[0]] = v[1](r.variables[v[0]]);
        });

        let request = null;

        if (s !== null && s.request !== undefined) {
            request = s.request;

        } else if (limit > 0) {
            request = requestBodyInMemory(r, limit);
        }

        putBody(rec, 'request_body_njs', request);
        putBody(rec, 'response_body_njs', s === null ? null
                : {data: Buffer.concat(s.chunks, s.size), truncated: s.truncated});

        rec.request_headers_njs = copyHeaders(r.headersIn, redact);
        rec.response_headers_njs = copyHeaders(r.headersOut, redact);

    } catch (e) {
        rec.njs_log_error = String(e);
    }

    return JSON.stringify(rec);
}

export default {capture_request_body, capture_response_body, record};
