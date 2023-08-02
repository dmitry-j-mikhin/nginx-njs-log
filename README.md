# nginx-njs-log

This is example [docker image](https://hub.docker.com/r/dmikhin/nginx-njs-log) based on official
[nginx:1.24.0](https://hub.docker.com/layers/library/nginx/1.24.0/images/sha256-ce340e77bc930ee76c11741d9b4764b65fa9ab25f1a7e181e824fceceb3a6ca7?context=explore)
stable image with support of full request(headers+body) and response(headers+body) logging using [njs](https://nginx.org/en/docs/njs/).
For more details check:
* [scripts/logging.js](scripts/logging.js)
* [scripts/default_addon.conf](scripts/default_addon.conf)

Image can be executed with [run.sh](run.sh) script:
```Shell
$ ./run.sh
```
Send example request:
```Shell
$ curl 127.0.0.1 -d "example request body payload"
```
Latest log record formatted with [jq](https://github.com/jqlang/jq):
```JSON
$ docker logs -n 1 nginx | jq
{
  "source": "nginx",
  "msec": 1690974762.229,
  "time_iso8601": "2023-08-02T11:12:42+00:00",
  "request_time": 0.001,
  "body_bytes_sent": 157,
  "bytes_sent": 314,
  "request_length": 171,
  "http_host": "127.0.0.1",
  "http_user_agent": "curl/7.68.0",
  "remote_addr": "172.17.0.1",
  "request_method": "POST",
  "request_uri": "/",
  "status": 405,
  "upstream_addr": "127.0.0.1:8080",
  "request_body_njs": "example request body payload",
  "response_body_njs": "<html>\r\n<head><title>405 Not Allowed</title></head>\r\n<body>\r\n<center><h1>405 Not Allowed</h1></center>\r\n<hr><center>nginx/1.24.0</center>\r\n</body>\r\n</html>\r\n",
  "request_headers_njs": {
    "Host": "127.0.0.1",
    "User-Agent": "curl/7.68.0",
    "Accept": "*/*",
    "Content-Length": "28",
    "Content-Type": "application/x-www-form-urlencoded"
  },
  "response_headers_njs": {
    "Content-Type": "text/html",
    "Content-Length": "157"
  }
}
```
Also logs can be sent to [external syslog server](http://nginx.org/en/docs/syslog.html):
```Shell
$ SYSLOG_SRV="syslog:server=172.17.0.1:5514,facility=local7,tag=nginx,severity=info" ./run.sh
```
Syslog output using [syslog2stdout](https://github.com/ossobv/syslog2stdout):
```Shell
$ ./syslog2stdout 5514
172.17.0.2:52961: local7.info: fafc6ae1c7f0 nginx: {"source": "nginx","msec": 1690981227.381,"time_iso8601": "2023-08-02T13:00:27+00:00","request_time": 0.001,"body_bytes_sent": 157,"bytes_sent": 314,"request_length": 171,"http_host": "127.0.0.1","http_user_agent": "curl/7.68.0","remote_addr": "172.17.0.1","request_method": "POST","request_uri": "/","status": 405,"upstream_addr": "127.0.0.1:8080","request_body_njs": "example request body payload","response_body_njs": "<html>\r\n<head><title>405 Not Allowed</title></head>\r\n<body>\r\n<center><h1>405 Not Allowed</h1></center>\r\n<hr><center>nginx/1.24.0</center>\r\n</body>\r\n</html>\r\n","request_headers_njs": {"Host":"127.0.0.1","User-Agent":"curl/7.68.0","Accept":"*/*","Content-Length":"28","Content-Type":"application/x-www-form-urlencoded"},"response_headers_njs": {"Content-Type":"text/html","Content-Length":"157"}}
```