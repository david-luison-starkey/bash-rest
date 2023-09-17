# bash-rest

[![License: MIT](https://img.shields.io/badge/License-MIT-orange.svg)](https://github.com/david-luison-starkey/bash-annotations/blob/main/LICENSE)
---
<div align="center">
    <h4>
        Light-weight web framework for Bash
    </h4>
</div>

---

## Introduction

`bash-rest` provides a similar (albeit simplistic) experience to `spring-web` for `Java`.

The script starts a basic webserver that serves http requests over locahost, where functions annotated with request mapping annotations 
are invoked when their respective endpoints are called.

At present, only path variables are parsed (e.g. request body and request parameters are not captured, and the presence of characters 
like '?' in a path variable interfere with parsing due to reliance on regex and lookarounds).

Default port is 3000.

## Usage

Arguments passed to annotated functions are path variables in order of appearance in endpoint.

1. Define functions and map them to unique endpoints:

```bash
#!/usr/bin/env bash

# controller.bash

source "./request_mapping.bash"

@get_mapping "/api/v1/{userId}/dashboard/{profileId}"
get_dashboard() {
    local user_id="${1}" 
    local profile_id="${2}"

# Configure valid http and json response
    cat <<EOF
HTTP/1.1 200
Content-Type: application/json

{
    "userId": "${user_id}",
    "profileId": "${profile_id}"
}
EOF
}

```

2. Start the webserver `bash bash-rest.bash controller.bash`. Arguments are paths to `sh` or `bash` files with request mapping annotated functions. 

3. Send request to the endpoint defined above:

```bash

curl -X GET "http://localhost:3000/api/v1/5499/dashboard/1" 

# { "userId": "5499", "profileId": "1" }

```

### Overriding default behaviour

`bash-rest` defines `bash_rest_404_not_found()` as a default function to handle instances when a requested endpoint cannot be found.

This can be overridden by simply defining your own implementation of `bash_rest_404_not_found()` in a file sourced by `bash-rest.bash`.

Template for custom implementation is:

```bash
bash_rest_404_not_found() {
	cat <<EOF
HTTP/1.1 404 NotFound
Content-Type: # e.g. text/html

# Desired 404 response here
EOF
}

```

## Credits

Request parsing and `netcat` implementation with named pipes is taken from https://dev.to/leandronsp/building-a-web-server-in-bash-part-i-sockets-2n8b
